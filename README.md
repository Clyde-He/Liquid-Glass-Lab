# Liquid Glass Lab

Liquid Glass Lab is a macOS research app for inspecting the two Glass authoring
pipelines available to Mac applications:

- AppKit `NSGlassEffectView` raw Recipe state, resolved Shader/Rim inputs, and
  controlled Overrides;
- public SwiftUI `Glass` plus runtime-gated private `_Glass` Semantic Usage
  roles and their generated Core Animation trees.

The app keeps the two identifier spaces separate. AppKit Variant/Subvariant
values must not be interpreted as SwiftUI Semantic Usage tags even when their
resolved trees share lower-level filters or effects.

## Repository map

- [`LiquidGlassLab/GlassLab`](./LiquidGlassLab/GlassLab): macOS app and runtime
  inspectors;
- [`Documentation`](./Documentation): measured behavior, lab architecture, and
  the research backlog;
- [`Golden`](./Golden): accepted per-OS captures and the semantic JSON
  comparator.

Start with:

- [AppKit Glass Reverse Engineering](./Documentation/AppKitGlassReverseEngineering.md)
- [SwiftUI Glass Reverse Engineering](./Documentation/SwiftUIGlassReverseEngineering.md)
- [Glass Lab Playground](./Documentation/GlassLabPlayground.md)
- [Glass Research Roadmap](./Documentation/GlassResearchRoadmap.md)

## Build

The current target is macOS 26.0+. Accepted per-OS captures currently include
the macOS 26.6 and macOS 27 beta Recipe/Recursive baselines, plus the macOS 27
SwiftUI Semantic Usage fixture.

```sh
xcodebuild \
  -project LiquidGlassLab.xcodeproj \
  -scheme LiquidGlassLab \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## Private API warning

This repository intentionally probes private AppKit, SwiftUI, SwiftUICore, and
Core Animation implementation details. Runtime access is capability-checked so
missing symbols and selectors can fail closed, but recipes, role tags, object
graphs, and ABI assumptions remain OS-build-specific. The lab is research
infrastructure, not a promise of App Store-safe or cross-version-stable API.
