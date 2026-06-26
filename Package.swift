// swift-tools-version: 6.2
import PackageDescription

// Swift 6 + ExistentialAny, pinned so they can't regress.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

// Monorepo manifest: lives at the repo root (so `.package(url:)` resolves) while the Swift sources
// stay under swift/, alongside python/ and typescript/.
let package = Package(
    name: "AgentSquad",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "AgentSquad", targets: ["AgentSquad"]),
        .library(name: "AgentSquadMCP", targets: ["AgentSquadMCP"]),
        .library(name: "AgentSquadAudio", targets: ["AgentSquadAudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.1.0"),
    ],
    targets: [
        .target(name: "AgentSquad", path: "swift/Sources/AgentSquad", swiftSettings: swiftSettings),
        .target(
            name: "AgentSquadMCP",
            dependencies: ["AgentSquad", .product(name: "MCP", package: "swift-sdk")],
            path: "swift/Sources/AgentSquadMCP",
            swiftSettings: swiftSettings
        ),
        .target(name: "AgentSquadAudio", dependencies: ["AgentSquad"], path: "swift/Sources/AgentSquadAudio", swiftSettings: swiftSettings),
        .testTarget(name: "AgentSquadTests", dependencies: ["AgentSquad"], path: "swift/Tests/AgentSquadTests", swiftSettings: swiftSettings),
        .testTarget(name: "AgentSquadMCPTests", dependencies: ["AgentSquadMCP"], path: "swift/Tests/AgentSquadMCPTests", swiftSettings: swiftSettings),
        .testTarget(name: "AgentSquadAudioTests", dependencies: ["AgentSquadAudio"], path: "swift/Tests/AgentSquadAudioTests", swiftSettings: swiftSettings),
    ]
)
