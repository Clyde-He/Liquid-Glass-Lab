// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GlassHUDMaterial",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "GlassHUDMaterial",
            targets: ["GlassHUDMaterial"]
        ),
    ],
    targets: [
        .target(
            name: "GlassHUDMaterial",
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
            name: "GlassHUDMaterialTests",
            dependencies: ["GlassHUDMaterial"],
            path: "Tests/GlassHUDMaterialTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
