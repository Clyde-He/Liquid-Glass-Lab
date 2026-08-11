# Liquid Glass Lab

Liquid Glass Lab is a macOS research app for inspecting the two Glass authoring pipelines available to Mac applications:

- AppKit `NSGlassEffectView` raw Recipe state, resolved Shader/Rim inputs, and controlled Overrides;
- public SwiftUI `Glass` plus runtime-gated private `_Glass` Semantic Usage roles and their generated Core Animation trees.

The app keeps the two identifier spaces separate. AppKit Variant/Subvariant values must not be interpreted as SwiftUI Semantic Usage tags even when their resolved trees share lower-level filters or effects.

## Repository map

- [`LiquidGlassLab/GlassLab`](./LiquidGlassLab/GlassLab): macOS app and runtime inspectors;
- [`Documentation`](./Documentation): measured behavior, lab architecture, and the research backlog;
- [`Golden`](./Golden): accepted per-OS captures and the semantic JSON comparator.

Start with:

- [AppKit Glass Reverse Engineering](./Documentation/AppKitGlassReverseEngineering.md)
- [SwiftUI Glass Reverse Engineering](./Documentation/SwiftUIGlassReverseEngineering.md)
- [Glass Lab Playground](./Documentation/GlassLabPlayground.md)
- [Glass Research Roadmap](./Documentation/GlassResearchRoadmap.md)

## AdjustableGlass Swift Package

The repository root publishes the reusable `AdjustableGlass` library. Add the package by version and link its product from the consuming target:

```swift
dependencies: [
    .package(
        url: "https://github.com/Clyde-He/Liquid-Glass-Lab.git",
        from: "0.1.0"
    ),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AdjustableGlass", package: "liquid-glass-lab"),
        ]
    ),
]
```

`AdjustableGlassEffectView` is available on macOS 26 and later. The package can still be linked by an app whose deployment target is macOS 15 so the app can retain its existing fallback on older systems.

| macOS | Product status |
|---|---|
| 26 | Bundled catalog; measured and visually accepted |
| 27 | Bundled catalog; measured and visually accepted |
| Other major | Runtime calibration fallback; not release-certified |

See the [product integration guide](./LiquidGlassLab/GlassMaterial/README.md), [changelog](./CHANGELOG.md), and [release process](./RELEASING.md) for the supported API and compatibility contract.

## Build

The Glass runtime is available on macOS 26.0+. The Swift Package itself can be linked by applications that retain an older deployment target; consumers gate `AdjustableGlassEffectView` at runtime and keep their pre-macOS-26 fallback. Accepted per-OS captures currently include the macOS 26.6 and macOS 27 beta Recipe/Recursive baselines, plus the macOS 27 SwiftUI Semantic Usage fixture.

```sh
xcodebuild \
  -project LiquidGlassLab.xcodeproj \
  -scheme LiquidGlassLab \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The reusable product module and its independent consumer compile as a Swift Package:

```sh
swift test
xcodebuild \
  -project LiquidGlassLab.xcodeproj \
  -target GlassHUDConsumerDemo \
  build
```

`GlassHUDConsumerDemo` imports only the public `AdjustableGlass` product. The macOS-major Catalog is carried by the package resource bundle; consuming apps do not run the Lab's Capture workflow. Its frame-cadence logger is disabled by default so an idle demo represents product energy use; set the scheme environment variable `ADJUSTABLE_GLASS_FRAME_MONITOR=1` only while profiling Tint drag presentation.

## Private API warning

This repository intentionally probes private AppKit, SwiftUI, SwiftUICore, and Core Animation implementation details. Runtime access is capability-checked so missing symbols and selectors can fail closed, but recipes, role tags, object graphs, and ABI assumptions remain OS-build-specific. The lab is research infrastructure, not a promise of App Store-safe or cross-version-stable API.

## License

Liquid Glass Lab and `AdjustableGlass` are available under the [MIT License](./LICENSE).
