// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndonCord",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AndonCordApp", targets: ["AndonCordApp"]),
        .executable(name: "andon-hook", targets: ["andon-hook"]),
        .library(name: "AndonKit", targets: ["AndonKit"]),
    ],
    targets: [
        // Shared model + integration layer. No AppKit/SwiftUI dependency so the
        // hook shim can link it without dragging in the UI frameworks.
        .target(
            name: "AndonKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The shim Claude Code actually executes. Must stay tiny and fail open.
        .executableTarget(
            name: "andon-hook",
            dependencies: ["AndonKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AndonCordApp",
            dependencies: ["AndonKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AndonKitTests",
            dependencies: ["AndonKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
