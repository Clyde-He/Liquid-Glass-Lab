# SwiftUI Glass Reverse Engineering

This document records measured behavior of public SwiftUI `Glass` and private
SwiftUI `_Glass`: semantic roles, runtime delivery, generated Core Animation
composition, overlap with AppKit Recipe primitives, Main participation, and
potential customization surfaces. Private symbols and layouts may change on
every OS build.

For AppKit raw Variant/Subvariant recipes, formulas, Shader/Rim payloads, and
mutation contracts, see
[AppKit Glass Reverse Engineering](./AppKitGlassReverseEngineering.md).
For the Liquid Glass Lab controls, window lifecycle, Inspectors, exports, and
failure behavior, see [Glass Lab Playground](./GlassLabPlayground.md).
For prioritized private-authoring probes, unresolved axes, production-renderer
evaluation criteria, and cross-platform follow-up, see
[Glass Research Roadmap](./GlassResearchRoadmap.md).

## Evidence levels and test environment

The findings use three evidence levels:

- **Rendered and measured**: captured from the live SwiftUI/Core Animation tree
  and stored in the accepted Golden fixture.
- **Callable**: invoked through a runtime-gated symbol and rendered successfully.
- **Symbol inventory only**: an exported runtime entry exists, but its ABI and
  visual behavior have not yet been exercised by the Playground.

Current measured environment:

- macOS 27.0 beta, build `26A5378n`, arm64;
- Xcode 27 beta SDK;
- SwiftUI content hosted in an `NSHostingView` inside the controlled Panel;
- Width 480, Height 200, Corner Radius 16, Window Margin 40;
- all 24 roles captured at real Main Off and main-only On participation.

The accepted 48-entry source is
[`semantic-usage-trees.json`](../Golden/macOS-27/semantic-usage-trees.json).

## Platform scope: closer to iOS, but not yet verified on iOS

This SwiftUI path is architecturally closer to Liquid Glass on iOS than the
AppKit `NSGlassEffectView` path. Public `Glass`, private `_Glass`, semantic
roles, Shape-aware composition, interaction state, and environment-driven
resolution live in SwiftUI/SwiftUICore rather than AppKit. They are therefore
the relevant model when investigating a cross-platform SwiftUI Glass surface.

That relationship is an architectural inference, not evidence that both
platforms produce identical output. Everything measured in this document was
captured on macOS 27. The following still require an iOS runtime capture before
they can be claimed as shared behavior:

- the complete private role set and its tag order;
- the generated layer, filter, and effect topology;
- resolved parameter values and Main/active-environment behavior;
- private modifier ABI, availability, and rendering semantics.

In particular, `NSGlassEffectView` is an AppKit implementation detail and is
not the SwiftUI/iOS Glass abstraction. The shared primitives observed in the
resolved Core Animation tree do not make the two authoring pipelines the same.

## Mental model: `_Glass` is a descriptor, not a View

`NSGlassEffectView` is a concrete AppKit object. Private selectors configure
that object, AppKit resolves a Recipe, and the resulting CAFilter/SDF payload
can be inspected or restamped.

SwiftUI `Glass` and private `_Glass` are values passed to `glassEffect(_:in:)`.
They describe intent. SwiftUI combines that descriptor with Shape, geometry,
environment, interaction, and real window participation, then constructs a
larger layer graph:

```text
Glass / private _Glass descriptor
  + Shape / Geometry / Environment / Interaction / Main
                         |
                         v
             SwiftUI semantic graph builder
                         |
                         v
SDFLayer
|- optional displacementMap
|- glassBackground base
|- optional displacementMap portal
|- optional glassForeground
|- optional gradient / shadow / Siri layers
`- optional highlight passes
```

There is therefore no long-lived `_Glass` object to mutate through Objective-C
KVC. Customization can happen before resolution by producing another descriptor,
or after resolution by locating and restamping the generated filters/effects.

## Public customization surface

The macOS 27 SwiftUI interface exposes the macOS 26+ public surface:

| Area | Public API |
|---|---|
| Material | `Glass.regular`, `.clear`, `.identity` |
| Appearance | `tint(_:)` |
| Behavior | `interactive(_:)` |
| Geometry | `glassEffect(_:in:)` accepts any `Shape` |
| Composition | `GlassEffectContainer(spacing:)`, `glassEffectUnion`, `glassEffectID` |
| Transition | `glassEffectTransition` with matched-geometry, materialize, or identity behavior |

This layer is the stable product API. It intentionally does not expose raw
blur, refraction, displacement, gradient, or SDF-highlight values.

### Materialize transition inventory

The macOS 26.5 SDK exposes the public
`GlassEffectTransition.materialize`, `matchedGeometry`, and `identity`
transitions. It does not expose a public transition named `dissolve`; in the
research roadmap, “Dissolve” provisionally names the removal direction of a
materialize transition rather than an established fourth API case.

The same SDK's SwiftUICore symbol inventory exposes an internal
`GlassContainer.AppearanceSettings` with static presets named `materialize`
and `match`. Its visible property symbols are `scale`, `maxPointScale`, and
`blurRadius`, plus `reduceMotion(_:)`. This is static inventory evidence for a
coordinated appearance endpoint/vector. It does not yet establish the preset's
numeric values, whether interpolation changes Shader/SDF inputs, whether the
timing is role-specific, or whether removal reverses insertion.

Materialize/Dissolve time-series capture is therefore part of the Material
Strength track rather than the deferred private-authoring backlog. The required
probe must separate endpoint settings, outer transaction timing, normalized
per-channel curves, semantic-role selection, insertion/removal direction, and
Reduced Motion behavior. Its full protocol and decision gate are recorded in
the Glass Research Roadmap.

## Private role space and runtime delivery

The current `_Glass.Variant.Role` tag order is:

| Tag | Role | Tag | Role |
|---:|---|---:|---|
| 0 | Regular | 12 | Focus Border |
| 1 | Identity | 13 | Keyboard |
| 2 | Clear | 14 | Sidebar |
| 3 | Dock | 15 | Control |
| 4 | App Icons | 16 | Loupe |
| 5 | Widgets | 17 | Slider |
| 6 | Text | 18 | Camera |
| 7 | AVPlayer | 19 | Cartouche Popover |
| 8 | FaceTime | 20 | Menu |
| 9 | Control Center | 21 | Siri |
| 10 | Notification Center | 22 | Siri Snippet |
| 11 | Monogram | 23 | Vibrant Fill |

These tags are not `NSGlassEffectView._variant` values and do not match the
ordinal order of `DesignLibrary.GlassMaterialProvider.Variant`.

The Playground resolves every role with `dlopen`/`dlsym`. Public `Glass` and
private `_Glass` are both 40 bytes on the measured macOS 27 runtime. On macOS
26.6 Build 25G5065a they are both 41 bytes with a 48-byte stride and matching
value-witness flags. Explicit OS profiles plus exact public/private layout
matching gate the opaque transfer into the public `glassEffect` path. Missing
roles render as Unavailable rather than creating a direct private symbol
dependency.

On the measured macOS 27 runtime, all 23 zero-argument getters and the parameterized
`text(tint:frost:normalizedFactor:)` factory are **callable**. The Text factory
currently receives three nil arguments so its private defaults remain intact.
The measured macOS 26.6 runtime exports only Regular, Identity, and Clear; all
three passed an isolated getter ABI smoke test, while the other 21 symbols are
absent. A rendered macOS 26 Semantic capture is still required before promoting
those three roles from callable to rendered evidence.

## The Semantic graph reuses the AppKit glass core

Semantic is a higher-level composition, not an unrelated rendering technology.
In the Golden fixture:

- 23 of 24 roles contain a `glassBackground` CAFilter; Focus Border is the only
  exception.
- Every present `glassBackground` exposes the same 77-key inventory measured in
  `NSGlassEffectView`.
- Semantic Regular's 66 numeric `glassBackground` values match the sampled
  AppKit raw Variant 0/1 Recipe; raw 0 and 1 coalesce in that context.
- Its 13 currently readable `CASDFKeyFillHighlightEffect` values also match the
  AppKit Rim pass.

At 480 x 200, the following inner `glassBackground` numeric mappings were
measured. “Exact” means all 66 numeric inputs match within capture precision; it
does not prove that SwiftUI internally calls the AppKit Variant setter.

| Semantic Usage | Measured AppKit base | Additional Semantic composition |
|---|---|---|
| Regular | raw 0/1, exact | standard SDF output + highlight |
| Clear | raw 2, exact | standard SDF output + highlight |
| Dock | raw 3, exact | standard SDF output + highlight |
| App Icons | raw 4, exact | omits the separate highlight pass |
| Widgets | raw 5, exact | standard SDF output + highlight |
| Text | raw 6, exact | gradient + highlight |
| AVPlayer / FaceTime | raw 2, exact | role-owned surrounding composition |
| Control Center | raw 9, exact | standard SDF output + highlight |
| Notification Center | raw 10, exact | standard SDF output + highlight |
| Monogram | raw 11, exact | gradient + highlight |
| Keyboard | raw 15, exact | standard SDF output + highlight |
| Sidebar | raw 16 when Main Off; raw 0/1 when Main On | standard composition |
| Loupe | raw 19, exact | displacement portal + foreground |
| Camera | raw 0 + `camera` exact when Main Off; diverges when Main On | camera-owned options |
| Cartouche Popover | raw 20, exact | standard composition |
| Menu | raw 0 + `menu`, exact | standard composition |
| Control / Slider | closest to raw 19 but not exact | two displacement passes + foreground |
| Identity | no meaningful raw equivalent | zero-sized/no-op treatment |
| Focus Border | no `glassBackground` | shadow + two glass highlights + gradient |
| Siri / Siri Snippet / Vibrant Fill | no exact raw Recipe | specialized semantic treatment |

## Usage-specific pass inventory

The 48-entry Golden contains four CAFilter families:

| Filter | Declared inputs | Purpose |
|---|---:|---|
| `glassBackground` | 77 | Shared blur, bleed, refraction, face, shadow, and highlight Recipe core |
| `displacementMap` | 4 | Displacement amount, mask, offset, and source-layer routing |
| `glassForeground` | 13 | Foreground edge and refraction treatment |
| `vibrantColorMatrix` | 4 | Backdrop-aware color transform, including an 80-byte color matrix value |

Observed effect families are:

- `CASDFOutputEffect`;
- `CASDFKeyFillHighlightEffect`;
- `CASDFGlassHighlightEffect`;
- `CASDFGlassDisplacementEffect`;
- `CASDFGradientEffect`;
- `CASDFGradientContourEffect`;
- `CASDFShadowEffect`.

Control and Slider each use two displacement passes plus foreground; Loupe uses
one displacement portal plus foreground. Text and Monogram add gradient passes.
Focus Border omits the background glass and builds an outline composition. Siri
adds `glassForeground`, a gradient contour, `SiriWaveLayer`, and
`SiriMetalLayer`.

An Effect with zero captured inputs is not proven constant or unmodifiable. It
only means the current Inspector's guarded key list has not found readable
properties for that class yet.

## Main participation is a Semantic input

The controlled `24 roles x Main Off/On` pass produced 48 accepted rows:

- requested and actual Main match in every row;
- actual Key is false in every row;
- every role is available and every row has a snapshot;
- Layer, Filter, Effect, and declared-input topology remains unchanged between
  Off and On for every role in this fixed environment;
- 19 of 24 roles change resolved values or pass opacity.

The five roles that are identical across Main are Identity, Text, Monogram,
Siri Snippet, and Vibrant Fill.

Of the 19 changing roles, 18 change `glassBackground` values and 18 change an
SDF highlight opacity. App Icons is Filter-only; Focus Border is Effect-only;
the other 17 change both. Standard highlight layers generally move from opacity
0 to 1, while Focus Border enables two `CASDFGlassHighlightEffect` layers.

Regular's Main On branch enables bleed, outer refraction, shadow, and highlight
values. Regular and Sidebar resolve to identical normalized snapshots in the
sampled Main On context even though their Main Off snapshots differ. This shows
that semantic roles may coalesce after environment resolution.

These findings are scoped to the fixed Panel/geometry capture. Size, Host,
interaction state, accessibility, appearance, and role-authoring options have
not yet been multiplied into the Semantic matrix.

## Private authoring customization inventory

The macOS 27 SwiftUICore export table contains a much larger private authoring
surface. Except where marked callable above, the following are **symbol
inventory only** and must not yet be treated as safe Playground controls.

### Factories and interpolation

- `text(tint:frost:normalizedFactor:)`;
- `vibrantFill(black:white:saturation:normalFill:blurRadius:)`;
- `explicit(Material)`;
- `mix(with:by:)`;
- the 24 named role getters.

### Appearance and geometry

- `tintColor`, `controlTint`, and `fixedBackgroundColor`;
- `frost`, `smoothness`, `surfaceSize`, and `minimumDimension`;
- `focusOffset`, `sharpTinting`, and `boostWhitePoint`;
- fixed/initial adaptive luminance and adaptive hysteresis ranges.

### Context and pass selection

- `forceActiveAppearance`, `forceSubdued`, and `forceScrim`;
- `forceReducedTransparency` and `forceIncreasedContrast`;
- `disableEdgeBleed` and `disableOuterRefraction`;
- `excludingForeground`, `excludingShadow`, and `excludingPlatter`;
- `excludeContent`, `contentHidden`, and `contentEffect`;
- control displacement/lensing exclusion;
- `coplanar`, `meshed`, color-scheme, and external-luminance options.

### Interaction and specialized content

- `interactive` and explicit idle, rollover, pressed, deeply pressed, or
  disabled interaction state;
- Siri wave personality, opacity, anchor point, power level, and audio-meter
  inputs;
- lossless, lossy, or disabled optimization levels.

These APIs operate on a Swift value and generally return a new `_Glass`. Calling
them dynamically requires the exact Swift ABI for the receiver, return value,
and any nested private argument type. A symbol's presence proves neither ABI
safety nor a visual mutation contract.

## Resolved-pass customization

After SwiftUI creates the CA graph, its filters and effects can potentially be
overridden like the AppKit Recipe payload:

1. locate passes by filter name/effect class and structural path;
2. capture typed values and layer opacity;
3. write only keys declared by that exact filter or proven writable effect;
4. relocate and restamp after SwiftUI replaces layers or re-resolves context.

The existing NSGlass 77-key metadata is a useful seed for the Semantic
`glassBackground` group, but it cannot describe the entire graph. Displacement,
foreground, vibrancy, gradients, shadows, and specialized Siri content need
their own type, range, mutation-lifetime, and restoration experiments.

Fixed layer indexes are not a safe identity: Usage changes can add or remove
whole passes. Focus Border has no base background, while Control, Slider, and
Siri own multi-pass graphs. A Semantic Override should therefore be organized
by present pass rather than presenting one universal knob list.

## Future research

Unresolved SwiftUI work is tracked centrally in
[Glass Research Roadmap](./GlassResearchRoadmap.md). It separates safe ABI
discovery, authoring-level probes, resolved-pass mutation, missing environment
axes, macOS 26 comparison, iOS validation, and the explicit gate for considering
SwiftUI as a production renderer.
