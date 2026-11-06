// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DTMCPClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DTMCPCore", targets: ["DTMCPCore"]),
        .executable(name: "DTMCPClient", targets: ["DTMCPClient"]),
    ],
    dependencies: [
        .package(path: "reference/DrawThings-Swift"),
        // No tagged release (latest 0.9.0) ships the HTTP server transports yet; pin a main commit.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk",
            revision: "c97779c2eff637576963db8831479e43ab17d569"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Everything except UI: settings, folder grants, jobs, output, generation, MCP server.
        .target(
            name: "DTMCPCore",
            dependencies: [
                .product(name: "DrawThingsClient", package: "DrawThings-Swift"),
                .product(name: "DrawThingsQueue", package: "DrawThings-Swift"),
                .product(name: "DrawThingsVideoKit", package: "DrawThings-Swift"),
                .product(name: "DrawThingsKit", package: "DrawThings-Swift"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Resources/skill")]
        ),
        // SwiftUI app. Packaged into a sandboxed, signed .app by Scripts/build-app.sh.
        .executableTarget(
            name: "DTMCPClient",
            dependencies: ["DTMCPCore"]
        ),
        .testTarget(
            name: "DTMCPCoreTests",
            dependencies: ["DTMCPCore"]
        ),
    ]
)
