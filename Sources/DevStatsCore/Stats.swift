public struct Usage: Sendable, Equatable {
  public var used: Int64
  public var total: Int64

  public init(used: Int64, total: Int64) {
    self.used = used
    self.total = total
  }

  public var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// The kernel's own judgement of memory health; more meaningful than used % on macOS,
/// which deliberately keeps RAM full.
public enum MemoryPressure: Sendable, Equatable {
  case normal, warning, critical
}

/// Resident memory summed across every process sharing a name.
public struct ProcessGroup: Sendable, Equatable {
  public var name: String
  public var bytes: Int64

  public init(name: String, bytes: Int64) {
    self.name = name
    self.bytes = bytes
  }
}

public struct MachineStats: Sendable, Equatable {
  /// 0...1 across all cores; nil until two samples exist.
  public var cpu: Double?
  public var memory: Usage
  public var memoryPressure: MemoryPressure?
  public var swap: Usage
  public var disk: Usage
  public var load: [Double]
  public var cores: Int
  /// Largest memory users; nil when this sample didn't ask for them.
  public var top: [ProcessGroup]?
}

public struct CPUTicks: Sendable, Equatable {
  public var busy: UInt64
  public var total: UInt64

  func usage(since previous: CPUTicks) -> Double? {
    guard total > previous.total, busy >= previous.busy else { return nil }
    return Double(busy - previous.busy) / Double(total - previous.total)
  }
}

/// One raw reading. CPU usage needs the delta between two of these.
public struct Snapshot: Sendable {
  public var stats: MachineStats
  public var ticks: CPUTicks

  public func stats(since previous: Snapshot?) -> MachineStats {
    var stats = stats
    stats.cpu = previous.flatMap { ticks.usage(since: $0.ticks) }
    return stats
  }
}

/// Groups processes by name and keeps the `limit` largest.
func largestGroups(_ processes: some Sequence<ProcessGroup>, limit: Int) -> [ProcessGroup] {
  var totals: [String: Int64] = [:]
  for process in processes {
    totals[process.name, default: 0] += process.bytes
  }
  return totals
    .sorted { $0.value > $1.value }
    .prefix(limit)
    .map { ProcessGroup(name: $0.key, bytes: $0.value) }
}
