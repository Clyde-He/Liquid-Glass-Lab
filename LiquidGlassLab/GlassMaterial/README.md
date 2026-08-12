# AdjustableGlass

An `NSGlassEffectView` subclass with adjustable effect amount and deterministic active/inactive material state.

`view.alphaValue = 0.5` fades the finished composite, destroying tint, blur, refraction, edge lighting, and contrast together. This coordinates the underlying passes instead, so intermediate values still read as glass.

## Product integration

Add this repository as a Swift Package and link the `AdjustableGlass` product. The only public top-level type is `AdjustableGlassEffectView`; it privately owns catalog loading, calibration, Tint synthesis, material installation, retries, and fail-closed fallback.

```swift
import AppKit
import AdjustableGlass

let glassView = AdjustableGlassEffectView(
    referenceWindow: settingsWindow,
    referenceView: appKitReferenceView
)
glassView.contentView = hudContentView
glassView.cornerRadius = 24
glassView.style = .clear
glassView.effectAmount = 0.72       // effect strength, not alphaValue
glassView.appearance = nil          // system; or an NSAppearance override
glassView.tintColor = pickedColor
glassView.effectState = .active     // or .inactive

glassView.onStatusChange = { status in
    // .idle / .waitingForReferenceWindow / .preparing / .ready
    // / .unavailable(reason)
}
```

The API intentionally follows `NSGlassEffectView` where AppKit already has the right vocabulary:

| API | Meaning |
|---|---|
| `contentView`, `cornerRadius` | Native AppKit behavior |
| `style` | Native `.regular` / `.clear` style |
| `tintColor` | Native property name backed by verified Tint installation |
| `appearance` | `nil` follows the system; an override pins Light or Dark |
| `effectAmount` | Added continuous glass amount in `0...1` |
| `effectState` | Added deterministic `.active` / `.inactive` material |
| `hasOuterShadow` | Retains the bounds-extending shadow; when `false`, the safety inset is 0pt on macOS 26 and 1pt on macOS 27 |
| `referenceWindow` | Optional, replaceable ordinary app window used for verification |
| `referenceView` | Optional consumer-owned AppKit insertion point for invisible verification probes |
| `setReferenceHost(window:view:)` | Atomically replaces the reference window and probe view as one host transition |
| `requiredWindowInset`, `onRequiredWindowInsetChange` | Transparent room required around the visual glass bounds |
| `status`, `onStatusChange`, `prepareIfNeeded()` | Readiness and retry surface |
| `performConfigurationUpdates(_:)` | Applies several property changes as one material transaction |

`status` describes current readiness, not a terminal lifecycle. An `.unavailable` view can recover automatically after a material-install retry, Tint resolution, reference-window activation, or runtime recalibration; keep observing `onStatusChange` rather than treating the first unavailable value as a permanent fallback decision.

When supplied, `referenceWindow` must be an ordinary window that can genuinely become main or key, such as Settings or the app's primary window. The rendered glass can live in a nonactivating HUD panel and never become main or key itself. The reference may be nil at launch and replaced later without recreating the glass or its `contentView`. A certified base atlas, a Tint inside the major's certified synthesis domain, and a previously verified exact cached Tint can become ready without it; new runtime calibration or an unseen Tint outside that domain waits until a reference window is available and participating.

Change a window and its probe view together with `setReferenceHost(window:view:)` — one host transition, unlike two separate property writes. The reference host is a calibration/resolver capability, not ownership of the rendered material: detaching it (including when the reference window itself closes) leaves an already verified, frozen material and a resolved Tint on screen unchanged, while genuinely unresolved calibration or Tint work waits for a participating replacement host. Rebinding the same host pair is a no-op.

When `referenceWindow` is managed by SwiftUI, provide `referenceView` from an `NSViewRepresentable` installed in that window's content. AppKit does not support adding subviews directly to `NSHostingController.view`; the package therefore never uses a view-controller-owned content root as an implicit probe host. A plain AppKit window with no `contentViewController` may omit `referenceView` and uses its `contentView` as the insertion point.

The packaged `glass-macos-<major>.json` is discovered from the Swift Package resource bundle automatically. On macOS 26 and 27, every color representable by Display P3 is synthesized synchronously from its original extended-sRGB components into an in-memory overlay; no clamp, ordinary-sRGB conversion, capture, or per-color write is involved. A color outside the current major's certified domain is resolved only through the genuinely participating probe pair; after the complete eight-cell result passes frozen readback, the Provider may atomically retain it in the consumer app's bounded, exact-RGB, macOS-major-scoped runtime cache. Runtime base calibration and these verified Tint overlays may therefore be cached under the consumer app's Caches directory; the product does not supply or coordinate JSON files.

`active` and `inactive` are product semantics, not trusted labels in a JSON file. Both are installed from the same paired atlas transaction. On a certified major an in-gamut Tint is available in the same synchronous configuration update, resolved from the accepted closed form.

A color the closed form does not cover — for example a gamut wider than Display P3 on macOS 26 or 27, or any color on an uncertified major — is resolved by asking the system instead of extrapolating: the controller keeps a warm, invisible probe set in the host window plus a nonparticipating witness, sets the color, and reads the matrix back in one `CATransaction` commit. The first such color pays a one-time probe materialization (`status` reports `preparing`); every later color change costs one commit. Unknown domains remain fail-closed — see the [Tint Parameterization Study](../../Documentation/TintParameterizationStudy.md).

All sources fail closed. Resolution order is certified model → exact compatible cache → legal-host resolver → wait. The requested color appears only once every cell of the selected participation has a verified matrix; the product never presents a hue-suppressed live fallback as a configured Tint. A commit result first lives on a temporary Atlas copy for the current presentation, then only a complete, paired eight-cell result is promoted to the bounded runtime overlay. Partial/unverified results, nearby RGB values, and mismatched schema/macOS-major environments are never reused. Commit resolution needs the host window to be genuinely main or key at the moment of the pick; otherwise the color stays withheld and `status` reports `waitingForReferenceWindow`.

Run the independent `GlassHUDConsumerDemo` app scheme from Xcode. To compile it from the command line:

```sh
xcodebuild \
  -project LiquidGlassLab.xcodeproj \
  -target GlassHUDConsumerDemo \
  build
```

That app target links the local package product and imports only `AdjustableGlass`; it has no Controller, Atlas, Strength, or Capture API. The demo's diagnostic display link is disabled by default so it does not create a permanent 60 fps workload. Set `ADJUSTABLE_GLASS_FRAME_MONITOR=1` in the scheme environment only when collecting `frames/s`, `longestGap`, and dropped-frame logs during a Tint drag.

This package intentionally relies on private AppKit implementation details and is intended for Direct Distribution, not the Mac App Store.

## Lab internals

## Freeze a style atlas

Live mode follows the window: lose main, and the glass re-reads Subdued endpoints. To lock a glass to a participation its window never has — a HUD panel that should always render the Main-On material — capture a `GlassMaterialStyleAtlas` and freeze it.

`GlassMaterialAtlasProvider` is the controller's internal calibration engine. It remains available to the Lab target for capture and diagnostics but is not part of the Swift Package's public product API. Point it at a window that is genuinely main while the user works in it (the app's own Settings or main window). It calibrates Main-On probes clipped inside that window against same-context Main-Off witnesses in a transparent nonactivating panel. Window flags schedule the attempt but never certify it: every appearance × Regular/Clear × size pair must prove the active rim gate plus an independent render-margin or shader-vector branch difference, then both Normal and Muted consumers must pass frozen readback before anything is published or persisted.

```swift
let provider = GlassMaterialAtlasProvider(
    hostWindow: settingsWindow,
    probeHostView: appKitReferenceView,
    shortSides: [48, 64, 96, 128, 160, 200, 320],
    storageURL: runtimeAtlasFileURL,
    certifiedAtlasURLs:
        GlassMaterialAtlasCatalog.bundledAtlasURLs()
)
provider.onAtlasUpdated = { atlas in
    hudGlass.materialStrength.freeze(atlas: atlas)
}
provider.ensureCaptured()  // certified → verified cache → runtime calibration

// Capture-on-pick while Settings is genuinely active:
provider.captureTintMatrices(for: pickedColor) { locked in ... }
```

`onAtlasUpdated` never receives a partial base calibration. `ready` means the entire paired atlas has evidence and both participation branches passed a frozen-destination round-trip. `atlasSource` distinguishes bundled certification, a runtime cache, and a fresh calibration. Product code normally observes the higher-level controller status instead of coordinating these callbacks itself.

The manual sweep below remains the separate laboratory reference. Provider and reference artifacts must not share a file: otherwise one path can mask or overwrite the other during acceptance.

```swift
// One key-window opportunity yields the whole atlas: participation is the
// only axis that needs real window state; appearance and variant are forced
// on the probe, and each cell is sampled at several short sides.
var atlas = GlassMaterialStyleAtlas()
for cell in cellsToCapture {          // appearance × variant × participation
    configure(probeGlass, for: cell)  // NSAppearance override, variant, size
    for size in probeSizes {          // bracket the HUD's size range
        resize(probeGlass, to: size)  // …and let it lay out and settle
        atlas.add(GlassMaterialStyleSample.capture(from: probeGlass)!, for: cell)
    }
}
atlas.environment = .current(for: probeWindow.screen)

hudGlass.materialStrength.freeze(atlas: atlas)   // false if stale or partial
hudGlass.materialStrength.value = 0.5            // interpolates the frozen style
```

An atlas is a **disposable, proven cache**, not a universal document. `freeze` installs nothing unless the requested cells have supported topology; a Main-On freeze additionally requires every served sample to carry a same-context Main-Off witness and pass both participation signals. The product controller admits either semantic branch only after the whole paired provider transaction passes. A bundled certified catalog is keyed by capture schema and macOS major: `glass-macos-26.json`, `glass-macos-27.json`, and so on. Minor, patch, and beta builds within that major intentionally share the accepted snapshot. Display signature and exact build remain encoded for diagnostics but are not admission gates.

Certified JSON is an acceleration and release-certification path, not something the consuming product coordinates and not a promise of cross-version compatibility. On an unknown macOS major the controller automatically calibrates, validates, caches, and reports readiness. If a same-major catalog no longer fits the live private topology, full frozen readback stays false; after materialization retries the controller discards that candidate and runs paired calibration. This makes the catalog a pinned major-version look without making structural incompatibility look ready.

Only participation is frozen. Appearance and variant stay live — Light/Dark/ Auto and Regular/Clear switch by selecting atlas cells with no recapture — and size follows by piecewise-linear interpolation between each cell's samples, so a content-sized surface needs no recapture on resize either. Several channels, including the render bounds that prevent the clipped-ring artifact, depend on both participation and size; sampling is what serves them without an authored per-channel ratio/cap table. Choose probe sizes that bracket the surface's range plus the resolver's gates (the ≤64pt floor and the 64–160pt blur ramp).

Each sample carries the restampable transplant groups: every typed shader input including captured nils, the render-bounds group, both untinted color grades with their scalar inputs, and the full rim payload — a flat context resolves zero-alpha rim colors, so the gate alone would open onto an invisible highlight. The atlas is `Codable`: capture once, certify one snapshot per macOS major, and retain exact-build/display metadata only for diagnostics. The chosen product policy values a stable major-version look over following minor Recipe drift; a handful of resolved fields are display-sensitive, but a display change alone does not invalidate the catalog.

One transplant group cannot be restamped and falls on the host layout: **window room**. The backing surface hard-clips everything at the window frame, so the glass must sit inset by at least the sample's `marginWidth` inside a transparent window — a content-sized HUD whose glass fills its panel edge-to-edge will still clip the Main-On outer passes no matter what this module writes. Size the panel to its visual content plus `requiredWindowInset` on every side and respond to `onRequiredWindowInsetChange` when size, style, participation, or calibration changes. Keep the visual content size fixed and grow the panel outward by the reported inset; deriving the glass bounds back from the expanded panel can create a size/inset feedback loop. Window dragging, snapping, and hit testing should continue to use the visual glass frame rather than the larger transparent panel frame.

A frozen style needs an active defense rather than a single write. AppKit restamps parts of the tree for the window's *real* participation one cycle after certain events — a rim effect replacement re-derives `marginWidth`, a resize re-derives it even when the rim carries over, and a drag burst or variant switch can revert the shader inputs while leaving rim and margin untouched — always later than any write in the same apply, with size-dependent delay. A frozen apply therefore replaces the rim effect only when its payload actually differs (which also removes the per-frame effect copy during a `value` scrub) and arms a bounded verify-and-repeat whose sentinel checks margin, the rim payload, and the written shader vector itself, re-applying while any of them reads back wrong. Measured on the acceptance HUD: contexts and drag bursts converge within ~200ms; the flash of system-resolved material during that window is the residual cost, corrected at the next beat.

Tint under a frozen participation needs one extra calibration. The Provider captures and stores both Main-On and Main-Off matrices per appearance × variant cell, admits them only while the same tinted probes pass the paired base-style proof, then requires all eight frozen consumers to read back before commit. Tint accumulates independently of the size samples and is keyed by source RGB: a new color calibrates eight matrices, never a new size atlas, and alpha stays a runtime coefficient (`sourceAlpha × value²`) on the captured hue. The product controller keeps the requested tint offscreen until that transaction verifies.

`unfreeze()` returns to live behavior at the next rebuild. One caveat is inherited from an open research question: whether AppKit writes an intermediate Recipe during active/inactive transitions before the restamp runs (roadmap P2). `AdjustableGlassEffectView` refreshes on window main/key, application activation, and appearance notifications, plus a follow-up main-actor job — this covers the common orderings but does not establish a deterministic final writer until that question is settled by capture.

## Take it

Copy this directory. It has no dependency on the rest of Liquid Glass Lab — nine Swift files plus any certified JSON catalogs, AppKit only:

| File | Role |
|---|---|
| `GlassMaterialAccess.swift` | The minimum private-API surface: layer lookup, filter read/write, render bounds, rim gate/payload, color matrices |
| `GlassMaterialCurve.swift` | The measured curve: shapes, channel table, baseline |
| `GlassMaterialAtlas.swift` | The captured style atlas: appearance × variant × participation × size samples, Codable, interpolated |
| `GlassMaterialAtlasCatalog.swift` | Discovers conventionally named `glass-macos-<major>.json` resources |
| `GlassMaterialAtlasProvider.swift` | Product calibration: certified catalog loading, paired On/Off proof, atomic persistence, tint-on-pick |
| `GlassMaterialStrength.swift` | Internal strength writer plus the public `AdjustableGlassEffectView` |
| `GlassEffectController.swift` | Internal ownership of active/inactive selection, provider, retries, Tint gating, and status |

The current lab ships `Catalog/glass-macos-27.json`. Its raw JSON is about 199 KB and compresses to about 6.5 KB; adding one catalog per macOS major is therefore negligible compared with ordinary app assets. Arbitrary user tint colors remain runtime-calibrated and cached because they cannot be exhaustively pre-bundled.

## How it works

Endpoints are **read from the live Recipe**, never hard-coded. Each channel resolves as:

```text
value(g) = start + (endpoint - start) × shape(g)
```

That is why size, appearance, Regular/Clear, window participation, and subvariant all follow automatically: the system already resolved the right endpoint for the current context, and `g = 1` reproduces it by construction. This statement is exact at the 200pt reference geometry. At 48pt, SwiftUI briefly uses a different adaptive face grade at the Materialize animation endpoint before settling back to the static Recipe; that two-endpoint exception is called out below.

`refresh()` distinguishes a replacement filter from the controller's own near-1 write using the filter identity and last authored face opacity. If the current Variant has no `glassBackground`, it clears the cached baseline and reports `isAvailable == false` instead of carrying an endpoint over from the previous Variant.

One update resolves the filter name and `inputKeys` capability set once, then reuses that target for every channel. Tint matrix writes are capability-guarded and disable implicit Core Animation actions just like background and Rim writes.

What remains authored is only five dimensionless shapes:

```text
linear         g
quadraticFlat  0.2g + 0.8g²                 blur opacity 1/2, no Main
quadratic      0.4g + 0.6g²                 blur opacity 1/2 with Main, and 3/4
height         g + c·g(1-g)                 the shadow-height family
clamp          (0.34g + 0.036g²) / 0.376    Clear's inputClamp
```

`c` is `min(0.2, 16 / shortSide)`. Materialize inflates the SDF element's short side by `min(0.2 · shortSide, 16)` points and retracts it with the outer transaction. That View Envelope clock is distinct from face-opacity `g`, even though the two are close in a one-second linear capture.

## What is verified

Measured on **macOS 26** and **macOS 27** for public **Regular and Clear** in a panel, served by one table with no version branch. Each accepted direct archive contains 104 runs / 936 samples across appearance, backdrop, participation, tint, both directions, and `shortSide` 48/200/400. Evidence lives in `Golden/macOS-26/`, `Golden/macOS-27/`, and the P1.1 section of [Glass Research Roadmap](../../Documentation/GlassResearchRoadmap.md).

The executable learnings currently pass 33/33 on macOS 26. At the 200pt reference size the single-endpoint curve replays the measured continuous channels; across 48/200/400 every remaining channel stays inside the documented geometry bound. A resize/rebuild test confirms the authored strength survives AppKit replacing the whole subtree.

Targeted author visual acceptance of the compact product HUD path is complete on both macOS 26 and macOS 27, including size-dependent rendering and the platform-specific safety inset with Outer Shadow disabled.

## What is not

- **Private semantic roles and non-panel hosts** were never sampled.
- **Visual acceptance is the author's, not instrumented.** It is a release acceptance step rather than an executable test.
- **Runtime cost is unmeasured.** Do not drive this from a high-frequency update loop without profiling first.

## Known limits

Three behaviors are discrete by measurement and cannot be smoothed: the rim gate opens at any `value > 0`; `inputSDRHoldingToneEnabled` adopts its Recipe value at any `value > 0`; and Clear in DarkAqua steps `inputBleedDarkenBlend` at `0.5`.

Mid-transition accuracy degrades away from a ~200pt short side, bounded by `min(5%, 4 / shortSide)` — 5% at 48pt, 1% at 400pt, shrinking above that. The cause is that a channel pinned to a cap stops tracking the inflating geometry and reads as linear, and which channels are capped depends on size.

There is one separate exception: at 48pt, removal traverses both the long-lived static Recipe and a different Materialized face grade. A single captured baseline therefore cannot exactly replay `inputFaceColorMatrixBlack` and `inputFaceColorMatrixWhite` for that path. The curve remains monotonic and exact at its chosen static endpoints, but matching that compact transition requires a future dual-endpoint adaptive face-grade model.

Setting `value = 1` does not uninstall the override. Restoring the true system material requires a fresh `NSGlassEffectView`.

## Stability

This drives private CALayer filter and SDF-effect state. Every access is selector- and `inputKeys`-guarded, so a renamed or removed key degrades to "channel not written" rather than a crash — but a macOS release can still change the curve itself. Re-run the fixtures in `Golden/` against a new OS before shipping on it.
