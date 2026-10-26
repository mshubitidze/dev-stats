import Foundation

public struct LimitWindow: Sendable, Equatable {
  /// Window length, e.g. "5h" or "7d".
  public var span: String
  public var fraction: Double
  public var resetsAt: Date?

  /// Usage as of `date`: a window whose reset time has passed is empty again.
  public func fraction(at date: Date) -> Double {
    if let resetsAt, resetsAt <= date { 0 } else { fraction }
  }
}

public struct AccountLimits: Sendable, Equatable, Identifiable {
  public enum Provider: String, Sendable {
    case claude, codex
  }

  public var provider: Provider
  public var email: String
  /// Shortest window first.
  public var windows: [LimitWindow]
  public var error: String?

  public var id: String { "\(provider.rawValue):\(email)" }

  /// The email's domain without its TLD: "acme" for me@acme.dev.
  public var name: String {
    email.split(separator: "@").last?.split(separator: ".").first.map(String.init) ?? email
  }
}

/// Subscription limits for every account CLIProxyAPI holds on the remote host.
///
/// The usage endpoints are the private ones Claude Code and Codex use for their own usage
/// screens. The script runs remotely so OAuth tokens never leave the host, and it returns
/// only the usage fields.
public enum LimitsSampler {
  static let script = """
    import glob, json, os, urllib.request
    from concurrent.futures import ThreadPoolExecutor

    ENDPOINTS = {
        "claude": "https://api.anthropic.com/api/oauth/usage",
        "codex": "https://chatgpt.com/backend-api/wham/usage",
    }
    KEEP = {"claude": ("five_hour", "seven_day"), "codex": ("rate_limit",)}

    def fetch(path):
        try:
            with open(path) as file:
                account = json.load(file)
        except (OSError, ValueError):
            return None
        if not isinstance(account, dict):
            return None
        provider = account.get("type")
        if provider not in ENDPOINTS or account.get("disabled"):
            return None
        headers = {"Authorization": "Bearer " + account.get("access_token", ""), "User-Agent": "DevStats"}
        if provider == "claude":
            headers["anthropic-beta"] = "oauth-2025-04-20"
        else:
            headers["chatgpt-account-id"] = account.get("account_id", "")
        result = {"provider": provider, "email": account.get("email", "")}
        try:
            request = urllib.request.Request(ENDPOINTS[provider], headers=headers)
            with urllib.request.urlopen(request, timeout=8) as response:
                usage = json.load(response)
            result["usage"] = {key: usage.get(key) for key in KEEP[provider]}
        except Exception as error:
            result["error"] = str(error)[:200]
        return result

    # CLIProxyAPI's default auth-dir.
    paths = sorted(glob.glob(os.path.expanduser("~/.cli-proxy-api/*.json")))
    with ThreadPoolExecutor() as pool:
        print(json.dumps([result for result in pool.map(fetch, paths) if result]))
    """

  @concurrent
  public static func fetch(host: String, timeout: Duration = .seconds(20)) async throws -> [AccountLimits] {
    let output = try await SSH.run(host: host, command: "python3 - <<'EOF'\n\(script)\nEOF", timeout: timeout)
    return try parse(Data(output.utf8))
  }

  public static func parse(_ data: Data) throws -> [AccountLimits] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([RawAccount].self, from: data).compactMap { raw in
      guard let provider = AccountLimits.Provider(rawValue: raw.provider) else { return nil }
      let windows = raw.usage.map { windows(from: $0, provider: provider) } ?? []
      let error = raw.error ?? (windows.isEmpty ? "No limits reported" : nil)
      return AccountLimits(provider: provider, email: raw.email, windows: windows, error: error)
    }
  }

  private static func windows(from usage: RawUsage, provider: AccountLimits.Provider) -> [LimitWindow] {
    switch provider {
    case .claude:
      return [("5h", usage.fiveHour), ("7d", usage.sevenDay)].compactMap { span, window in
        window.map { LimitWindow(span: span, fraction: $0.utilization / 100, resetsAt: $0.resetsAt.flatMap(date)) }
      }
    case .codex:
      return [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow]
        .compactMap { $0 }
        .sorted { $0.limitWindowSeconds < $1.limitWindowSeconds }
        .map { window in
          LimitWindow(
            span: span(seconds: window.limitWindowSeconds),
            fraction: window.usedPercent / 100,
            resetsAt: window.resetAt.map(Date.init(timeIntervalSince1970:))
          )
        }
    }
  }

  private static func span(seconds: Int) -> String {
    seconds % 86_400 == 0 ? "\(seconds / 86_400)d" : "\(Int((Double(seconds) / 3600).rounded()))h"
  }

  /// Claude's reset times jitter around the minute between requests (12:59:59.9, 13:00:00.07),
  /// so round to the minute they're meant to be.
  private static func date(_ string: String) -> Date? {
    let parsed = (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
      ?? (try? Date(string, strategy: .iso8601))
    return parsed.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
  }
}

private struct RawAccount: Decodable {
  var provider: String
  var email: String
  var usage: RawUsage?
  var error: String?
}

/// Claude reports `five_hour`/`seven_day`; Codex reports `rate_limit`.
private struct RawUsage: Decodable {
  struct ClaudeWindow: Decodable {
    var utilization: Double
    var resetsAt: String?
  }

  struct CodexRateLimit: Decodable {
    var primaryWindow: CodexWindow?
    var secondaryWindow: CodexWindow?
  }

  struct CodexWindow: Decodable {
    var usedPercent: Double
    var limitWindowSeconds: Int
    var resetAt: TimeInterval?
  }

  var fiveHour: ClaudeWindow?
  var sevenDay: ClaudeWindow?
  var rateLimit: CodexRateLimit?
}
