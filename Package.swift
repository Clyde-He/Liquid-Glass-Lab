// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AdjustableGlass",
    platforms: [
        // The product itself is runtime-gated to macOS 26, but keeping the
        // package consumable from older deployment targets lets applications
        // preserve their existing Material fallback below macOS 26.
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "AdjustableGlass",
            targets: ["AdjustableGlass"]
        ),
    ],
    targets: [
        .target(
            name: "AdjustableGlass",
            path: "LiquidGlassLab/GlassMaterial",
            exclude: [
                "README.md",
            ],
            resources: [
                .process("Catalog"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "AdjustableGlassTests",
            dependencies: ["AdjustableGlass"],
            path: "Tests/AdjustableGlassTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
