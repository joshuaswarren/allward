// swift-tools-version: 6.2
import PackageDescription

// Allward module graph. The dependency edges below are the normative map in
// docs/SPEC.md §2 "Module and target map". `AllwardHerdr` is an optional
// adapter: no core target may depend on it, which `AllwardNoHerdrTarget`
// proves at build time.

// The Darwin-only half of the graph (AppKit, Metal, forkpty, SpeechAnalyzer)
// cannot compile on Linux. Excluding it there is not a portability shim: it is
// how the portable engine, protocol, and surface reducers stay testable in a
// fast Linux CI job while the app targets stay macOS 26 only.
#if os(macOS)
    let darwinTargets: [Target] = [
        .target(name: "CAllwardPTY", path: "Sources/CAllwardPTY", publicHeadersPath: "include"),
        .target(
            name: "AllwardConfig",
            dependencies: ["AllwardCore", "AllwardRooms", "AllwardDesign"]
        ),
        .testTarget(name: "AllwardConfigTests", dependencies: ["AllwardConfig"]),
        .target(
            name: "AllwardLocalPTY",
            dependencies: ["AllwardCore", "AllwardRemote", "CAllwardPTY"]
        ),
        .target(name: "AllwardSSH", dependencies: ["AllwardCore", "AllwardRemote", "AllwardLocalPTY"]),
        .target(name: "AllwardHerdr", dependencies: ["AllwardCore", "AllwardMultiplexer", "AllwardRemote"]),
        .target(
            name: "AllwardLocalPublisherEndpoint",
            dependencies: ["AllwardCore", "AllwardProtocol"]
        ),
        .target(name: "AllwardRenderer", dependencies: ["AllwardCore", "AllwardTerminal", "AllwardDesign"]),
        .target(name: "AllwardIntelligence", dependencies: ["AllwardCore", "AllwardSurfaces"]),
        .target(name: "AllwardSpeech", dependencies: ["AllwardCore"]),
        .target(
            name: "AllwardControl",
            dependencies: [
                "AllwardCore", "AllwardTerminal", "AllwardRemote", "AllwardMultiplexer",
                "AllwardSurfaces", "AllwardRooms", "AllwardConfig", "AllwardLocalPTY", "AllwardSSH",
            ]
        ),
        .target(name: "AllwardConcierge", dependencies: ["AllwardCore", "AllwardControl"]),
        .target(
            name: "AllwardMCP",
            dependencies: [
                "AllwardCore", "AllwardControl", "AllwardSurfaces", "AllwardRemote",
                "AllwardTerminal",
            ]
        ),
        .target(
            name: "AllwardChrome",
            dependencies: [
                "AllwardCore", "AllwardDesign", "AllwardRenderer", "AllwardControl",
                "AllwardSurfaces", "AllwardRooms", "AllwardSpeech", "AllwardIntelligence",
                "AllwardConcierge", "AllwardConfig", "AllwardProtocol",
                "AllwardLocalPublisherEndpoint", "AllwardHerdr", "AllwardMCP",
            ]
        ),
        .executableTarget(name: "allward", dependencies: ["AllwardChrome"]),
        .executableTarget(name: "allward-mcp", dependencies: ["AllwardMCP"]),
        .executableTarget(
            name: "allward-qa",
            dependencies: ["AllwardChrome", "AllwardDesign", "AllwardRenderer", "AllwardTerminal"]
        ),
        .testTarget(name: "AllwardControlTests", dependencies: ["AllwardControl"]),
        .testTarget(name: "AllwardSpeechTests", dependencies: ["AllwardSpeech"]),
        .testTarget(name: "AllwardMCPTests", dependencies: ["AllwardMCP"]),
        .testTarget(name: "AllwardChromeTests", dependencies: ["AllwardChrome"]),
        .testTarget(name: "AllwardRendererTests", dependencies: ["AllwardRenderer"]),
    ]
    let darwinProducts: [Product] = [
        .executable(name: "allward", targets: ["allward"]),
        .executable(name: "allward-mcp", targets: ["allward-mcp"]),
    ]
#else
    let darwinTargets: [Target] = []
    let darwinProducts: [Product] = []
#endif

let package = Package(
    name: "Allward",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AllwardCore", targets: ["AllwardCore"]),
        .library(name: "AllwardTerminal", targets: ["AllwardTerminal"]),
        .library(name: "AllwardProtocol", targets: ["AllwardProtocol"]),
        .library(name: "AllwardSurfaces", targets: ["AllwardSurfaces"]),
    ] + darwinProducts,
    targets: [
        // MARK: Portable core (builds on Linux; no AppKit, Metal, or Darwin-only API)

        .target(name: "AllwardCore"),
        .target(name: "AllwardTerminal", dependencies: ["AllwardCore"]),
        .target(name: "AllwardDesign", dependencies: ["AllwardCore"]),
        .target(name: "AllwardProtocol", dependencies: ["AllwardCore"]),
        .target(name: "AllwardRooms", dependencies: ["AllwardCore", "AllwardDesign"]),
        .target(
            name: "AllwardSurfaces",
            dependencies: ["AllwardCore", "AllwardProtocol", "AllwardRooms", "AllwardMultiplexer"]
        ),
        .target(name: "AllwardMultiplexer", dependencies: ["AllwardCore"]),
        .target(name: "AllwardRemote", dependencies: ["AllwardCore"]),

        // MARK: Tests

        .testTarget(name: "AllwardCoreTests", dependencies: ["AllwardCore"]),
        .testTarget(name: "AllwardTerminalTests", dependencies: ["AllwardTerminal"]),
        .testTarget(name: "AllwardProtocolTests", dependencies: ["AllwardProtocol"]),
        .testTarget(
            name: "AllwardSurfacesTests",
            dependencies: ["AllwardSurfaces", "AllwardRooms", "AllwardProtocol"]
        ),
        .testTarget(name: "AllwardDesignTests", dependencies: ["AllwardDesign", "AllwardRooms"]),
    ] + darwinTargets
)
