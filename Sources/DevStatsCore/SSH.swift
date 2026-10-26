import Foundation

public enum SSHError: Error, CustomStringConvertible {
  case unreachable
  case failed(status: Int32)
  case timedOut

  public var description: String {
    switch self {
    case .unreachable: "Can't reach host"
    case .failed(let status): "ssh exited with status \(status)"
    case .timedOut: "Timed out"
    }
  }
}

enum SSH {
  /// Reuses one SSH connection across polls without touching ~/.ssh/config.
  static let options = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=2",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/devstats-%C",
    "-o", "ControlPersist=10m",
  ]

  /// Runs `command` in the remote login shell and returns its stdout.
  static func run(host: String, command: String, timeout: Duration) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ssh")
    process.arguments = options + [host, command]
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
    case (.uncaughtSignal, _): throw SSHError.timedOut
    case (_, 0): break
    case (_, 255): throw SSHError.unreachable
    case (_, let status): throw SSHError.failed(status: status)
    }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }
}
