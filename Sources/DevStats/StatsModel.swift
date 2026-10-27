import AppKit
import DevStatsCore
import os

private let logger = Logger(subsystem: "com.misho.DevStats", category: "polling")

struct CPUSample: Identifiable {
  var date: Date
  var usage: Double
  var id: Date { date }
}

struct MachineState {
  static let historyWindow: TimeInterval = 120

  private(set) var stats: MachineStats?
  private(set) var cpuHistory: [CPUSample] = []
  var error: String?

  mutating func record(_ stats: MachineStats, at date: Date = .now) {
    // Keep the last top list through closed-panel polls so the panel opens at full height.
    let previousTop = self.stats?.top
    self.stats = stats
    if stats.top == nil {
      self.stats?.top = previousTop
    }
    error = nil
    if let cpu = stats.cpu {
      cpuHistory.append(CPUSample(date: date, usage: cpu))
    }
    cpuHistory.removeAll { date.timeIntervalSince($0.date) > Self.historyWindow }
  }
}

@Observable
final class StatsModel {
  /// Override with `defaults write com.misho.DevStats devboxHost <ssh-host>`.
  let devboxHost = UserDefaults.standard.string(forKey: "devboxHost") ?? "devbox"

  private(set) var mac = MachineState()
  private(set) var devbox = MachineState()
  /// nil until the first fetch completes.
  private(set) var limits: [AccountLimits]?
  private(set) var limitsError: String?

  /// Poll fast and sample top processes only while someone is looking.
  private var isPanelOpen = false {
    didSet { if isPanelOpen { pollNow() } }
  }

  @ObservationIgnored private var naps: Set<Task<Void, Never>> = []

  init() {
    Task { await pollMac() }
    Task { await pollDevbox() }
    Task { await pollLimits() }
    Task {
      for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
        pollNow()
      }
    }
    // The panel is the app's only window, so key status tracks whether it's open.
    // SwiftUI's onDisappear doesn't fire when a MenuBarExtra panel closes.
    Task {
      for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
        isPanelOpen = true
      }
    }
    Task {
      for await _ in NotificationCenter.default.notifications(named: NSWindow.didResignKeyNotification) {
        isPanelOpen = false
      }
    }
  }

  var macMemory: String { percent(mac.stats?.memory.fraction) }

  var devboxMemory: String { devbox.error == nil ? percent(devbox.stats?.memory.fraction) : "–" }

  /// The menu bar title in words, for VoiceOver.
  var accessibilityLabel: String {
    var title = "Mac memory \(macMemory), devbox memory \(devboxMemory)"
    if let claude = bestClaudeSession {
      title += ", Claude 5-hour limit \(percent(claude))"
    }
    return title
  }

  /// The Claude account with the most room left in its 5-hour window.
  var bestClaudeSession: Double? {
    let now = Date.now
    return limits?
      .filter { $0.provider == .claude }
      .compactMap { $0.windows.first { $0.span == "5h" }?.fraction(at: now) }
      .min()
  }

  private func pollMac() async {
    var previous: Snapshot?
    while true {
      let snapshot = await MacSampler.snapshot(includeTop: isPanelOpen)
      mac.record(snapshot.stats(since: previous))
      previous = snapshot
      await nap(isPanelOpen ? .seconds(1) : .seconds(5))
    }
  }

  private func pollDevbox() async {
    var previous: Snapshot?
    while true {
      do {
        let snapshot = try await LinuxSampler.snapshot(host: devboxHost, includeTop: isPanelOpen)
        devbox.record(snapshot.stats(since: previous))
        previous = snapshot
      } catch {
        logger.error("devbox poll failed: \(String(describing: error), privacy: .public)")
        devbox.error = String(describing: error)
        previous = nil
      }
      switch (isPanelOpen, devbox.error == nil) {
      case (true, true): await nap(.seconds(1))
      case (true, false): await nap(.seconds(3))
      case (false, true): await nap(.seconds(5))
      case (false, false): await nap(.seconds(30))
      }
    }
  }

  /// The usage endpoints are private and rate limited per account, and other clients (T3 Code,
  /// Claude Code) poll the same accounts. Bursts trip the limit, so limits refresh on a slow
  /// fixed schedule: opening the panel doesn't refetch, and a relaunch reuses a recent result.
  private func pollLimits() async {
    if let cache = LimitsCache.load() {
      limits = cache.accounts
      _ = try? await Task.sleep(for: .seconds(600 + cache.date.timeIntervalSinceNow))
    }
    while true {
      var interval = Duration.seconds(600)
      do {
        let fetched = try await LimitsSampler.fetch(host: devboxHost)
        // A failed account (often a transient rate limit) keeps its last known windows.
        limits = fetched.map { account in
          guard account.windows.isEmpty, let previous = limits?.first(where: { $0.id == account.id }) else {
            return account
          }
          var account = account
          account.windows = previous.windows
          return account
        }
        limitsError = nil
        if fetched.contains(where: { $0.error == "Rate limited" }) {
          interval = .seconds(1800)
        }
        LimitsCache(date: .now, accounts: limits ?? []).save()
      } catch {
        logger.error("limits poll failed: \(String(describing: error), privacy: .public)")
        limitsError = error is DecodingError ? "Unexpected response" : String(describing: error)
        // Usually the network isn't back yet after wake; the request never reached the provider.
        if case SSHError.unreachable = error {
          interval = .seconds(60)
        }
      }
      // Not a `nap`, so opening the panel doesn't cut it short. Task.sleep uses the continuous
      // clock, which counts through system sleep, so a refresh that came due overnight runs on wake.
      _ = try? await Task.sleep(for: interval)
    }
  }

  /// A sleep that `pollNow()` cuts short.
  private func nap(_ duration: Duration) async {
    let nap = Task { _ = try? await Task.sleep(for: duration) }
    naps.insert(nap)
    await nap.value
    naps.remove(nap)
  }

  private func pollNow() {
    naps.forEach { $0.cancel() }
  }
}

/// The last limits fetch, kept across launches.
private struct LimitsCache: Codable {
  private static let key = "limitsCache"

  var date: Date
  var accounts: [AccountLimits]

  static func load() -> LimitsCache? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LimitsCache.self, from: $0) }
  }

  func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
  }
}

func percent(_ fraction: Double?) -> String {
  fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "–"
}
