import Testing
@testable import DevStatsCore

struct LinuxSamplerTests {
  static let output = """
    load
    2.46 3.41 3.25 6/2406 1354468
    cores
    16
    stat
    cpu  5882898 25914 1369876 133284695 75871 0 51784 0 0 0
    mem
    MemTotal:       64011180 kB
    MemAvailable:   52839860 kB
    SwapTotal:       8388604 kB
    SwapFree:        8388604 kB
    disk
    /dev/nvme0n1p2 982240026624 59038371840 873231138816       7% /
    top
    8123456 node
    2048000 tmux: server
    """

  @Test func `parses every section`() throws {
    let stats = try LinuxSampler.parse(Self.output).stats
    #expect(stats.load == [2.46, 3.41, 3.25])
    #expect(stats.cores == 16)
    #expect(stats.memory == Usage(used: (64011180 - 52839860) * 1024, total: 64011180 * 1024))
    #expect(stats.swap == Usage(used: 0, total: 8388604 * 1024))
    #expect(stats.disk == Usage(used: 982240026624 - 873231138816, total: 982240026624))
    #expect(stats.top == [
      ProcessGroup(name: "node", bytes: 8123456 * 1024),
      ProcessGroup(name: "tmux: server", bytes: 2048000 * 1024),
    ])
  }

  @Test func `top section is optional`() throws {
    let output = Self.output.components(separatedBy: "top\n").first!
    #expect(try LinuxSampler.parse(output).stats.top == nil)
  }

  @Test func `groups processes by name, largest first`() {
    let processes = [("node", 3), ("zsh", 1), ("node", 4), ("cargo", 5), ("vim", 2)]
      .map { ProcessGroup(name: $0, bytes: $1) }
    let groups = largestGroups(processes, limit: 2)
    #expect(groups == [ProcessGroup(name: "node", bytes: 7), ProcessGroup(name: "cargo", bytes: 5)])
  }

  @Test func `counts idle and iowait as not busy`() throws {
    let ticks = try LinuxSampler.parse(Self.output).ticks
    let total: UInt64 = 5882898 + 25914 + 1369876 + 133284695 + 75871 + 51784
    #expect(ticks == CPUTicks(busy: total - 133284695 - 75871, total: total))
  }

  @Test func `cpu usage is the busy share of the tick delta`() throws {
    var first = try LinuxSampler.parse(Self.output)
    var second = first
    first.ticks = CPUTicks(busy: 100, total: 1000)
    second.ticks = CPUTicks(busy: 150, total: 1200)
    #expect(second.stats(since: first).cpu == 0.25)
    #expect(second.stats(since: nil).cpu == nil)
  }

  @Test func `missing section throws`() {
    #expect(throws: LinuxSampler.ParseError.self) {
      try LinuxSampler.parse("load\n1 2 3 1/2 3\n")
    }
  }
}
