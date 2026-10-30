import Foundation
import Testing
@testable import DevStatsCore

struct SimulatorsSamplerTests {
  static let output = """
    status
    {"devices":[\
    {"id":"dev_1","spec":{"physical":false,"platform":"ios","model":"iPhone 17 Pro","osVersion":"26.5"},"state":"ready","workerId":"w_mac"},\
    {"id":"dev_2","spec":{"physical":false,"platform":"android","model":"Pixel 8","osVersion":"36"},"state":"leased","workerId":"w_devbox"},\
    {"id":"dev_3","spec":{"physical":false,"platform":"ios","model":"iPad Air","osVersion":"26.5"},"state":"leased","workerId":"w_mac"},\
    {"id":"dev_4","spec":{"physical":true,"platform":"watchos","model":"Watch","osVersion":"12"},"state":"ready"}],\
    "leases":[\
    {"id":"lease_t3","deviceId":"dev_2","requesterId":"lease_t3","ownerId":"tok_t3","grantedAt":1793364984138},\
    {"id":"w_mac.lse_b","deviceId":"dev_3","requesterId":"claude-code:abc","grantedAt":1793364000000}],\
    "waiting":[{"platform":"ios"}],\
    "workers":[\
    {"id":"w_mac","label":"mac","connection":"connected"},\
    {"id":"w_devbox","label":"devbox","connection":"disconnected"}]}
    tokens
    {"tokens":[{"id":"tok_t3","role":"agent","label":"t3-mac","createdAt":1793363829601}]}
    """

  @Test func `names each lease's holder and worker, leased devices first`() throws {
    let pool = try SimulatorsSampler.parse(Self.output)
    #expect(pool.devices.map(\.model) == ["Pixel 8", "iPad Air", "iPhone 17 Pro"])
    #expect(pool.devices[0].holder == "t3-mac")
    #expect(pool.devices[0].worker == "devbox")
    #expect(pool.devices[0].version == "Android 36")
    #expect(pool.devices[0].leasedAt == Date(timeIntervalSince1970: 1_793_364_984.138))
    #expect(pool.devices[1].holder == "claude-code:abc")
    #expect(pool.devices[2].holder == nil)
    #expect(pool.devices[2].state == "ready")
  }

  @Test func `counts waiting requests and offline workers`() throws {
    let pool = try SimulatorsSampler.parse(Self.output)
    #expect(pool.waiting == 1)
    #expect(pool.offlineWorkers == ["devbox"])
  }

  @Test func `still reads the pool without the token list`() throws {
    let output = Self.output.components(separatedBy: "tokens\n").first!
    #expect(try SimulatorsSampler.parse(output).devices[0].holder == "lease_t3")
  }
}
