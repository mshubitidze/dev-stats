import Foundation

public enum LinuxSampler {
  public enum Failure: Error, CustomStringConvertible {
    case unreachable
    case sshFailed(status: Int32)
    case timedOut
    case missing(String)

    public var description: String {
      switch self {
      case .unreachable: "Can't reach host"
      case .sshFailed(let status): "ssh exited with status \(status)"
      case .timedOut: "Timed out"
      case .missing(let field): "Couldn't read \(field)"
      }
    }
  }

  /// Each section is preceded by a bare marker line so parsing doesn't depend on output shapes.
  static func command(includeTop: Bool) -> String {
    var command = """
      echo load; cat /proc/loadavg; \
      echo cores; nproc; \
      echo stat; head -1 /proc/stat; \
      echo mem; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo; \
      echo disk; df -B1 -P / | tail -1
      """
    if includeTop {
      // RSS in KiB summed per command name, largest first.
      command += """
        ; echo top; ps -eo rss=,comm= \
        | awk '{ rss = $1; $1 = ""; sub(/^ +/, ""); total[$0] += rss } END { for (name in total) print total[name], name }' \
        | sort -rn | head -3
        """
    }
    return command
  }

  /// Reuses one SSH connection across polls without touching ~/.ssh/config.
  static let sshOptions = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/devstats-%C",
    "-o", "ControlPersist=10m",
  ]

  @concurrent
  public static func snapshot(host: String, includeTop: Bool, timeout: Duration = .seconds(10)) async throws -> Snapshot {
    try parse(try await ssh(host: host, command: command(includeTop: includeTop), timeout: timeout))
  }

  private static func ssh(host: String, command: String, timeout: Duration) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh")
    process.arguments = sshOptions + [host, command]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let watchdog = Task {
      try await Task.sleep(for: timeout)
      process.terminate()
    }
    defer { watchdog.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }

    switch (process.terminationReason, process.terminationStatus) {
    case (.uncaughtSignal, _): throw Failure.timedOut
    case (_, 0): break
    case (_, 255): throw Failure.unreachable
    case (_, let status): throw Failure.sshFailed(status: status)
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  public static func parse(_ output: String) throws -> Snapshot {
    let markers: Set<String> = ["load", "cores", "stat", "mem", "disk", "top"]
    var lines: [String: [Substring]] = [:]
    var current: String?
    for line in output.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if markers.contains(trimmed) {
        current = trimmed
      } else if let current {
        lines[current, default: []].append(line)
      }
    }
    let sections = lines.mapValues { $0.map { $0.split(separator: " ") } }

    guard let loadFields = sections["load"]?.first, loadFields.count >= 3 else { throw Failure.missing("load") }
    let load = loadFields.prefix(3).compactMap { Double($0) }

    guard let coresField = sections["cores"]?.first?.first, let cores = Int(coresField) else {
      throw Failure.missing("cores")
    }

    // cpu user nice system idle iowait irq softirq steal
    guard let stat = sections["stat"]?.first, stat.first == "cpu", stat.count >= 9 else {
      throw Failure.missing("cpu")
    }
    let jiffies = stat[1...8].compactMap { UInt64($0) }
    guard jiffies.count == 8 else { throw Failure.missing("cpu") }
    let total = jiffies.reduce(0, +)
    let ticks = CPUTicks(busy: total - jiffies[3] - jiffies[4], total: total)

    var meminfo: [Substring: Int64] = [:]
    for fields in sections["mem"] ?? [] where fields.count >= 2 {
      meminfo[fields[0].dropLast()] = Int64(fields[1]).map { $0 * 1024 }
    }
    guard
      let memTotal = meminfo["MemTotal"], let memAvailable = meminfo["MemAvailable"],
      let swapTotal = meminfo["SwapTotal"], let swapFree = meminfo["SwapFree"]
    else { throw Failure.missing("meminfo") }

    // Filesystem 1-blocks Used Available Capacity Mounted
    guard
      let df = sections["disk"]?.first, df.count >= 6,
      let diskTotal = Int64(df[1]), let diskAvailable = Int64(df[3])
    else { throw Failure.missing("disk") }

    let top = lines["top"]?.compactMap { line -> ProcessGroup? in
      let fields = line.split(separator: " ", maxSplits: 1)
      guard fields.count == 2, let kibibytes = Int64(fields[0]) else { return nil }
      return ProcessGroup(name: String(fields[1]), bytes: kibibytes * 1024)
    }

    return Snapshot(
      stats: MachineStats(
        cpu: nil,
        memory: Usage(used: memTotal - memAvailable, total: memTotal),
        memoryPressure: nil,
        swap: Usage(used: swapTotal - swapFree, total: swapTotal),
        disk: Usage(used: diskTotal - diskAvailable, total: diskTotal),
        load: load,
        cores: cores,
        top: top
      ),
      ticks: ticks
    )
  }
}
