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
    VStack(alignment: .leading, spacing: 12) {
      // Ticks every minute so reset countdowns stay current between fetches.
      TimelineView(.everyMinute) { context in
        // One grid for every section so their columns line up.
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
          MachineRows(name: "Mac", state: model.mac)
          Divider().padding(.vertical, 4)
          MachineRows(name: "Devbox", state: model.devbox)
          Divider().padding(.vertical, 4)
          LimitsRows(limits: model.limits, error: model.limitsError, now: context.date)
        }
        .font(.callout)
        .monospacedDigit()
      }
      Divider()
      HStack {
        Toggle("Open at Login", isOn: $opensAtLogin)
          .toggleStyle(.checkbox)
          .onChange(of: opensAtLogin) { _, enabled in setOpensAtLogin(enabled) }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
      .font(.callout)
    }
    .padding(14)
    .frame(width: 360)
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
              Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
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
          .font(.caption)
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
    .font(.caption)
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
    font(.caption).foregroundStyle(.secondary)
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
