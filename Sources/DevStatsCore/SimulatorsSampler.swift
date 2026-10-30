import Foundation

public struct PoolDevice: Sendable, Equatable, Identifiable {
  public enum Platform: String, Sendable {
    case ios, android
  }

  public var id: String
  public var platform: Platform
  public var model: String
  public var osVersion: String
  /// Simlock's own word for it: "leased", "ready" (booted and free), "booting", "reclaiming"...
  public var state: String
  /// The worker it runs on, by label.
  public var worker: String
  /// Who leased it: the token's label for agents such as T3, else Simlock's requester id.
  public var holder: String?
  public var leasedAt: Date?

  /// "iOS 26.5" or "Android 36".
  public var version: String { "\(platform == .ios ? "iOS" : "Android") \(osVersion)" }
}

public struct PoolStatus: Sendable, Equatable {
  /// Leased devices first, then by worker and model.
  public var devices: [PoolDevice]
  /// Lease requests waiting for a device.
  public var waiting: Int
  /// Workers the gateway has lost, by label.
  public var offlineWorkers: [String]
}

/// Simulators and emulators in the Simlock pool, read from the gateway on the remote host.
///
/// Runs the gateway's own CLI over SSH: it has the admin role there, so it can name each
/// lease's token, and no token has to live on this Mac.
public enum SimulatorsSampler {
  /// A login shell, because simlock is installed under a Node version manager.
  static let command = "bash -lc 'echo status; simlock --gateway status --json; echo tokens; simlock --gateway token list'"

  @concurrent
  public static func fetch(host: String, timeout: Duration = .seconds(15)) async throws -> PoolStatus {
    try parse(try await SSH.run(host: host, command: command, timeout: timeout))
  }

  public static func parse(_ output: String) throws -> PoolStatus {
    var sections: [String: Data] = [:]
    var current: String?
    for line in output.split(separator: "\n") {
      if line == "status" || line == "tokens" {
        current = String(line)
      } else if let current {
        sections[current, default: Data()].append(contentsOf: line.utf8)
      }
    }
    let decoder = JSONDecoder()
    let status = try decoder.decode(RawStatus.self, from: sections["status"] ?? Data())
    // The token list only adds names; the pool is still worth showing without it.
    let tokens = sections["tokens"].flatMap { try? decoder.decode(RawTokens.self, from: $0) }?.tokens ?? []
    let tokenLabels = Dictionary(tokens.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
    let workerLabels = Dictionary(status.workers.map { ($0.id, $0.label ?? $0.id) }, uniquingKeysWith: { first, _ in first })
    let leases = Dictionary(status.leases.map { ($0.deviceId, $0) }, uniquingKeysWith: { first, _ in first })

    let devices = status.devices.compactMap { raw -> PoolDevice? in
      guard let platform = PoolDevice.Platform(rawValue: raw.spec.platform) else { return nil }
      let lease = leases[raw.id]
      return PoolDevice(
        id: raw.id,
        platform: platform,
        model: raw.spec.model,
        osVersion: raw.spec.osVersion,
        state: raw.state,
        worker: raw.workerId.flatMap { workerLabels[$0] } ?? "",
        holder: lease.map { tokenLabels[$0.ownerId ?? $0.requesterId] ?? $0.requesterId },
        leasedAt: lease.map { Date(timeIntervalSince1970: $0.grantedAt / 1000) }
      )
    }
    return PoolStatus(
      devices: devices.sorted {
        ($0.leasedAt == nil ? 1 : 0, $0.worker, $0.model) < ($1.leasedAt == nil ? 1 : 0, $1.worker, $1.model)
      },
      waiting: status.waiting.count,
      offlineWorkers: status.workers.filter { $0.connection != "connected" }.map { $0.label ?? $0.id }
    )
  }
}

private struct RawStatus: Decodable {
  struct Device: Decodable {
    struct Spec: Decodable {
      var platform: String
      var model: String
      var osVersion: String
    }

    var id: String
    var spec: Spec
    var state: String
    var workerId: String?
  }

  struct Lease: Decodable {
    var deviceId: String
    /// Through agent-device this is the lease id the client chose, not who asked.
    var requesterId: String
    /// The token that took the lease, when it came over HTTP.
    var ownerId: String?
    /// Milliseconds since 1970.
    var grantedAt: Double
  }

  struct Worker: Decodable {
    var id: String
    var label: String?
    var connection: String
  }

  /// Only its length is used.
  struct Waiting: Decodable {}

  var devices: [Device]
  var leases: [Lease]
  var waiting: [Waiting]
  var workers: [Worker]
}

private struct RawTokens: Decodable {
  struct Token: Decodable {
    var id: String
    var label: String
  }

  var tokens: [Token]
}
