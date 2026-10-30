import Charts
import DevStatsCore
import ServiceManagement
import SwiftUI
import os

private let logger = Logger(subsystem: "com.misho.DevStats", category: "login")

struct StatsPanel: View {
  let model: StatsModel
  @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Ticks every minute so reset countdowns stay current between fetches.
      TimelineView(.everyMinute) { context in
        // One grid for every section so their columns line up.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
          MachineRows(name: "Mac", state: model.mac)
          Divider().padding(.vertical, 4)
          MachineRows(name: "Devbox", state: model.devbox)
          Divider().padding(.vertical, 4)
          SimulatorsRows(pool: model.pool, error: model.poolError, now: context.date)
          Divider().padding(.vertical, 4)
          LimitsRows(limits: model.limits, error: model.limitsError, now: context.date)
        }
        .monospacedDigit()
      }
      .padding(.horizontal, 6)
      Divider().padding(.horizontal, 6)
      // Menu items, per the HIG: checkmark for a setting in effect, shortcut on the right.
      VStack(spacing: 0) {
        Button("Open at Login") {
          opensAtLogin.toggle()
          setOpensAtLogin(opensAtLogin)
        }
        .buttonStyle(MenuItemStyle(isChecked: opensAtLogin))
        Button("Quit DevStats") { NSApplication.shared.terminate(nil) }
          .buttonStyle(MenuItemStyle(shortcut: "⌘Q"))
          .keyboardShortcut("q")
      }
    }
    .padding(.horizontal, 8)
    .padding(.top, 14)
    .padding(.bottom, 6)
    .frame(width: 380)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
  }

  private func setOpensAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      logger.error("login item change failed: \(error.localizedDescription, privacy: .public)")
      opensAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

/// Grid rows for one machine; views outside a `GridRow` span the full width.
private struct MachineRows: View {
  let name: String
  let state: MachineState

  var body: some View {
    SectionHeader(title: name, detail: state.stats.map { "\($0.cores) cores" }, error: state.error)
    if let stats = state.stats {
      Group {
        GridRow {
          Text("CPU")
          CPUChart(history: state.cpuHistory)
          let load = stats.load.map { $0.formatted(.number.precision(.fractionLength(2))) }
          Text(load.first.map { "load \($0)" } ?? "")
            .help(load.joined(separator: " · "))
            .detailStyle()
            .gridColumnAlignment(.trailing)
          Text(percent(stats.cpu))
            .gridColumnAlignment(.trailing)
        }
        UsageRow(label: "Memory", usage: stats.memory, unit: .memory, tint: memoryTint(stats))
        if stats.swap.total > 0 {
          UsageRow(label: "Swap", usage: stats.swap, unit: .memory, tint: .forUsage(stats.swap.fraction))
        }
        UsageRow(label: "Disk", usage: stats.disk, unit: .disk, tint: .forUsage(stats.disk.fraction))
        // Always present so the panel doesn't grow once the first list arrives.
        TopProcesses(groups: stats.top ?? []).fullWidthRow()
      }
      .opacity(state.error == nil ? 1 : 0.5)
    } else if state.error == nil {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity)
    }
  }

  private func memoryTint(_ stats: MachineStats) -> Color {
    switch stats.memoryPressure {
    case .normal: .accentColor
    case .warning: .orange
    case .critical: .red
    case nil: .forUsage(stats.memory.fraction)
    }
  }
}

private struct LimitsRows: View {
  let limits: [AccountLimits]?
  let error: String?
  let now: Date

  var body: some View {
    SectionHeader(title: "Limits", detail: nil, error: error)
    if let limits {
      Group {
        ForEach(limits) { account in
          HStack(spacing: 6) {
            Text(account.provider == .claude ? "Claude" : "Codex").fontWeight(.medium)
            Text(account.name).foregroundStyle(.secondary)
            Spacer()
            if let error = account.error {
              Text(error).font(.subheadline).foregroundStyle(.orange).lineLimit(1)
            }
          }
          .fullWidthRow()
          ForEach(account.windows, id: \.span) { window in
            LimitRow(window: window, now: now)
          }
        }
      }
      .opacity(error == nil ? 1 : 0.5)
    } else if error == nil {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity)
    }
  }
}

/// The Simlock pool across both workers: one line per device, leased ones first.
private struct SimulatorsRows: View {
  let pool: PoolStatus?
  let error: String?
  let now: Date

  var body: some View {
    SectionHeader(title: "Simulators", detail: detail, error: error ?? offline)
    if let pool {
      Group {
        if pool.devices.isEmpty {
          Text("None running").detailStyle().fullWidthRow()
        }
        ForEach(pool.devices) { device in
          HStack(spacing: 6) {
            Text(device.model).fontWeight(device.leasedAt == nil ? .regular : .medium).lineLimit(1)
            Text(device.version).foregroundStyle(.secondary).fixedSize()
            Spacer()
            Text([device.holder ?? status(device), device.worker].joined(separator: " · "))
              .detailStyle()
              .lineLimit(1)
              .truncationMode(.middle)
            if let leasedAt = device.leasedAt {
              Text(elapsed(since: leasedAt)).detailStyle().fixedSize()
            }
          }
          .opacity(device.leasedAt == nil ? 0.6 : 1)
          .help(device.holder.map { "Leased by \($0)" } ?? status(device))
          .fullWidthRow()
        }
      }
      .opacity(error == nil ? 1 : 0.5)
    } else if error == nil {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity)
    }
  }

  /// "2 in use · 1 waiting".
  private var detail: String? {
    guard let pool else { return nil }
    var parts = ["\(pool.devices.count { $0.leasedAt != nil }) in use"]
    if pool.waiting > 0 {
      parts.append("\(pool.waiting) waiting")
    }
    return parts.joined(separator: " · ")
  }

  private var offline: String? {
    guard let workers = pool?.offlineWorkers, !workers.isEmpty else { return nil }
    return "\(workers.joined(separator: ", ")) offline"
  }

  /// A free booted device is "idle"; anything else is mid-transition, in Simlock's words.
  private func status(_ device: PoolDevice) -> String {
    device.state == "ready" ? "idle" : device.state
  }

  /// "12m" or "1h 5m".
  private func elapsed(since date: Date) -> String {
    Duration.seconds(max(now.timeIntervalSince(date), 60))
      .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
  }
}

private struct LimitRow: View {
  let window: LimitWindow
  let now: Date

  var body: some View {
    let fraction = window.fraction(at: now)
    GridRow {
      Text(window.span)
      ProgressView(value: fraction).tint(.forUsage(fraction))
      Text(resetText).detailStyle()
      Text(percent(fraction))
    }
  }

  /// "in 1h 12m" within a day, otherwise "Sat 23:00".
  private var resetText: String {
    guard let resetsAt = window.resetsAt else { return "" }
    let remaining = resetsAt.timeIntervalSince(now)
    if remaining <= 0 {
      return "reset"
    }
    if remaining < 86_400 {
      let duration = Duration.seconds(max(remaining, 60))
      return "in " + duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
    return resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }
}

private struct SectionHeader: View {
  let title: String
  let detail: String?
  let error: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).font(.headline)
      if let detail {
        Text(detail).detailStyle()
      }
      Spacer()
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline)
          .foregroundStyle(.orange)
      }
    }
  }
}

private enum ByteUnit {
  /// Binary gigabytes, as Activity Monitor and `free` report RAM.
  case memory
  /// Decimal gigabytes, as Finder and drive vendors report storage.
  case disk

  private var base: Double { self == .memory ? 1024 : 1000 }

  func gigabytes(_ bytes: Int64) -> String {
    (Double(bytes) / (base * base * base)).formatted(.number.precision(.significantDigits(1...3)))
  }

  /// "3.6 GB" or "850 MB": two significant digits is plenty for a glance.
  func compact(_ bytes: Int64) -> String {
    let megabytes = Double(bytes) / (base * base)
    if megabytes < base {
      return "\(Int(megabytes.rounded())) MB"
    }
    return "\((megabytes / base).formatted(.number.precision(.significantDigits(1...2)))) GB"
  }
}

private struct UsageRow: View {
  let label: String
  let usage: Usage
  let unit: ByteUnit
  let tint: Color

  var body: some View {
    GridRow {
      Text(label)
      ProgressView(value: usage.fraction).tint(tint)
      Text("\(unit.gigabytes(usage.used)) / \(unit.gigabytes(usage.total)) GB").detailStyle()
      Text(percent(usage.fraction))
    }
  }
}

private struct CPUChart: View {
  let history: [CPUSample]

  var body: some View {
    let now = Date.now
    Chart(history) { sample in
      AreaMark(x: .value("Time", sample.date), y: .value("CPU", sample.usage))
        .foregroundStyle(.linearGradient(
          colors: [.accentColor.opacity(0.5), .accentColor.opacity(0.1)],
          startPoint: .top,
          endPoint: .bottom
        ))
      LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.usage))
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 1))
    }
    .chartXScale(domain: now.addingTimeInterval(-MachineState.historyWindow)...now)
    .chartYScale(domain: 0...1)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartPlotStyle { $0.background(.quaternary.opacity(0.6)) }
    .clipShape(.rect(cornerRadius: 3))
    .frame(height: 18)
    .help("Last 2 minutes")
  }
}

private struct TopProcesses: View {
  let groups: [ProcessGroup]

  var body: some View {
    HStack(spacing: 8) {
      Text("Top")
      ForEach(groups, id: \.name) { group in
        HStack(spacing: 3) {
          Text(group.name).lineLimit(1).truncationMode(.tail)
          Text(ByteUnit.memory.compact(group.bytes))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .help(group.name)
      }
    }
    .font(.subheadline)
  }
}

/// A full-width menu item: a checkmark column, the title, an optional shortcut, and a hover highlight.
private struct MenuItemStyle: ButtonStyle {
  var isChecked = false
  var shortcut: String?
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "checkmark")
        .fontWeight(.semibold)
        .frame(width: 14)
        .opacity(isChecked ? 1 : 0)
      configuration.label
      Spacer()
      if let shortcut {
        Text(shortcut).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 24)
    .contentShape(.rect)
    .background(.primary.opacity(isHovered ? 0.1 : 0), in: .rect(cornerRadius: 6))
    .opacity(configuration.isPressed ? 0.6 : 1)
    .onHover { isHovered = $0 }
  }
}

private extension Color {
  static func forUsage(_ fraction: Double) -> Color {
    switch fraction {
    case 0.9...: .red
    case 0.75...: .orange
    default: .accentColor
    }
  }
}

private extension View {
  func detailStyle() -> some View {
    font(.subheadline).foregroundStyle(.secondary)
  }

  /// Spans the whole grid without widening it: an overlay can't affect layout, so long
  /// content truncates to the width the columns leave.
  func fullWidthRow() -> some View {
    Color.clear
      .frame(height: 16)
      .overlay(alignment: .leading) { self }
      .gridCellUnsizedAxes(.horizontal)
  }
}
