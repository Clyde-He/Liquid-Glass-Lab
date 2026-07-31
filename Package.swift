// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AdjustableGlass",
    platforms: [
        .macOS(.v26),
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
