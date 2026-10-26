// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DevStats",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "DevStatsCore"),
    .executableTarget(
      name: "DevStats",
      dependencies: ["DevStatsCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(name: "DevStatsCoreTests", dependencies: ["DevStatsCore"]),
  ]
)
