import Foundation
import Testing
@testable import DevStatsCore

struct LimitsSamplerTests {
  static let output = """
    [
      {"provider": "claude", "email": "me@acme.dev", "usage": {
        "five_hour": {"utilization": 81.0, "resets_at": "2026-10-26T21:10:00.718467+00:00"},
        "seven_day": {"utilization": 26.0, "resets_at": "2026-11-01T18:59:59.93+00:00"}
      }},
      {"provider": "codex", "email": "me@acme.dev", "usage": {"rate_limit": {
        "primary_window": {"used_percent": 7, "limit_window_seconds": 604800, "reset_at": 1793607945},
        "secondary_window": {"used_percent": 40, "limit_window_seconds": 18000, "reset_at": 1793000000}
      }}},
      {"provider": "claude", "email": "me@work.example", "error": "HTTP Error 401: Unauthorized"},
      {"provider": "gemini", "email": "me@example.com", "usage": {}}
    ]
    """

  @Test func `parses claude windows, rounding resets to the minute`() throws {
    let claude = try LimitsSampler.parse(Data(Self.output.utf8))[0]
    #expect(claude.name == "acme")
    #expect(claude.windows.map(\.span) == ["5h", "7d"])
    #expect(claude.windows.map(\.fraction) == [0.81, 0.26])
    #expect(claude.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_049_000))
    #expect(claude.windows[1].resetsAt == Date(timeIntervalSince1970: 1_793_559_600))
  }

  @Test func `orders codex windows shortest first`() throws {
    let codex = try LimitsSampler.parse(Data(Self.output.utf8))[1]
    #expect(codex.windows.map(\.span) == ["5h", "7d"])
    #expect(codex.windows.map(\.fraction) == [0.4, 0.07])
    #expect(codex.windows[1].resetsAt == Date(timeIntervalSince1970: 1_793_607_945))
  }

  @Test func `keeps failed accounts and skips unknown providers`() throws {
    let accounts = try LimitsSampler.parse(Data(Self.output.utf8))
    #expect(accounts.count == 3)
    #expect(accounts[2].error == "HTTP Error 401: Unauthorized")
    #expect(accounts[2].windows.isEmpty)
  }
}
