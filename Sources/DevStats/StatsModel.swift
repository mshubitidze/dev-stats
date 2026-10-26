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

  /// Poll fast and sample top processes only while someone is looking.
  private var isPanelOpen = false {
    didSet { if isPanelOpen { pollNow() } }
  }

  @ObservationIgnored private var naps: Set<Task<Void, Never>> = []

  init() {
    Task { await pollMac() }
    Task { await pollDevbox() }
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

  var title: String {
    "Mac \(percent(mac.stats?.memory)) · Dev \(devbox.error == nil ? percent(devbox.stats?.memory) : "–")"
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

func percent(_ usage: Usage?) -> String {
  usage.map { percent($0.fraction) } ?? "–"
}

func percent(_ fraction: Double?) -> String {
  fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "–"
}
