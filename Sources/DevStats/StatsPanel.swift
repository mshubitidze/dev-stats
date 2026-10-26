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
      // One grid for both machines so their columns line up.
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        MachineRows(name: "Mac", state: model.mac)
        Divider().padding(.vertical, 4)
        MachineRows(name: "Devbox", state: model.devbox)
      }
      .font(.callout)
      .monospacedDigit()
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
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(name).font(.headline)
      if let stats = state.stats {
        Text("\(stats.cores) cores").detailStyle()
      }
      Spacer()
      if let error = state.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    if let stats = state.stats {
      Group {
        GridRow {
          Text("CPU")
          CPUChart(history: state.cpuHistory)
          Text(stats.load.first.map { "load \($0.formatted(.number.precision(.fractionLength(2))))" } ?? "")
            .help(stats.load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " · "))
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
        // Full-width and unsized, so long names truncate instead of widening the grid.
        Color.clear
          .frame(height: 16)
          .overlay(alignment: .leading) { TopProcesses(groups: stats.top ?? []) }
          .gridCellUnsizedAxes(.horizontal)
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
}
