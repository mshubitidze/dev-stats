import Darwin
import Foundation

private let host = mach_host_self()

public enum MacSampler {
  /// Off the caller's actor: scanning every process for the top list takes tens of milliseconds.
  @concurrent
  public static func snapshot(includeTop: Bool) async -> Snapshot {
    Snapshot(
      stats: MachineStats(
        cpu: nil,
        memory: memory(),
        memoryPressure: memoryPressure(),
        swap: swap(),
        disk: disk(),
        load: load(),
        cores: ProcessInfo.processInfo.activeProcessorCount,
        top: includeTop ? topProcesses() : nil
      ),
      ticks: ticks()
    )
  }

  /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
  private static func memory() -> Usage {
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    let total = Int64(ProcessInfo.processInfo.physicalMemory)
    guard result == KERN_SUCCESS else { return Usage(used: 0, total: total) }
    let pages = UInt64(info.internal_page_count) - UInt64(info.purgeable_count)
      + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
    return Usage(used: Int64(pages) * Int64(getpagesize()), total: total)
  }

  private static func memoryPressure() -> MemoryPressure? {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
    switch level {
    case 4: return .critical
    case 2: return .warning
    default: return .normal
    }
  }

  private static func swap() -> Usage {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return Usage(used: 0, total: 0) }
    return Usage(used: Int64(usage.xsu_used), total: Int64(usage.xsu_total))
  }

  private static func disk() -> Usage {
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
    guard
      let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
      let total = values.volumeTotalCapacity,
      let available = values.volumeAvailableCapacityForImportantUsage
    else { return Usage(used: 0, total: 0) }
    return Usage(used: Int64(total) - available, total: Int64(total))
  }

  private static func load() -> [Double] {
    var load = [Double](repeating: 0, count: 3)
    return getloadavg(&load, 3) == 3 ? load : []
  }

  private static func ticks() -> CPUTicks {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return CPUTicks(busy: 0, total: 0) }
    let (user, system, idle, nice) = info.cpu_ticks
    let busy = UInt64(user) + UInt64(system) + UInt64(nice)
    return CPUTicks(busy: busy, total: busy + UInt64(idle))
  }

  /// Uses phys_footprint, the figure Activity Monitor's Memory column shows.
  /// Processes owned by other users can't be inspected and are skipped.
  private static func topProcesses() -> [ProcessGroup] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let processes = pids.prefix(max(count, 0)).lazy.compactMap { pid -> ProcessGroup? in
      var usage = rusage_info_v2()
      let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
      }
      var name = [CChar](repeating: 0, count: 64)
      guard result == 0, proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
      let decoded = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return ProcessGroup(name: decoded, bytes: Int64(usage.ri_phys_footprint))
    }
    return largestGroups(processes, limit: 3)
  }
}
