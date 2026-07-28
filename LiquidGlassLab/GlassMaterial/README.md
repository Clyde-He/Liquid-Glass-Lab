# GlassMaterial

A continuous `0...1` material strength for `NSGlassEffectView` — a replacement
for `alphaValue` when you want "how much glass", not "how opaque".

`view.alphaValue = 0.5` fades the finished composite, destroying tint, blur,
refraction, edge lighting, and contrast together. This coordinates the
underlying passes instead, so intermediate values still read as glass.

## Use it

```swift
let strength = GlassMaterialStrength(glass: glassView)
strength.value = 0.5
```

Call `refresh()` after any layout pass, or use the provided subclass and forget
about it:

```swift
let glassView = GlassMaterialEffectView()
glassView.materialStrength.value = 0.5
```

If the glass has a public tint, hand it over so the tint branch tracks too:

```swift
strength.tintColor = glassView.tintColor
```

## Freeze a style atlas

Live mode follows the window: lose main, and the glass re-reads Subdued
endpoints. To lock a glass to a participation its window never has — a HUD
panel that should always render the Main-On material — capture a
`GlassMaterialStyleAtlas` from a probe glass and freeze it:

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

hudGlass.materialStrength.freeze(atlas: atlas)
hudGlass.materialStrength.value = 0.5   // interpolates the frozen style
```

Only participation is frozen. Appearance and variant stay live — Light/Dark/
Auto and Regular/Clear switch by selecting atlas cells with no recapture — and
size follows by piecewise-linear interpolation between each cell's samples, so
a content-sized surface needs no recapture on resize either. Several channels,
including the render bounds that prevent the clipped-ring artifact, depend on
both participation and size; sampling is what serves them without an authored
per-channel ratio/cap table. Choose probe sizes that bracket the surface's
range plus the resolver's gates (the ≤64pt floor and the 64–160pt blur ramp).

Each sample carries the restampable transplant groups: every typed shader
input including captured nils, the render-bounds group, both untinted color
grades with their scalar inputs, and the full rim payload — a flat context
resolves zero-alpha rim colors, so the gate alone would open onto an invisible
highlight. The atlas is `Codable`: capture once, persist, and recapture only
when the display configuration or OS build changes. Capture on the running
machine rather than burning in fixture values — a handful of resolved fields
are display-sensitive, which is why the `Golden/` archives are regression
references, not a runtime source.

One transplant group cannot be restamped and falls on the host layout:
**window room**. The backing surface hard-clips everything at the window
frame, so the glass must sit inset by at least the sample's `marginWidth`
inside a transparent window — a content-sized HUD whose glass fills its panel
edge-to-edge will still clip the Main-On outer passes no matter what this
module writes. Size the panel to content plus `marginWidth` padding;
`sample(for:at:)` exposes the captured value.

Tint under a frozen Main-On lock needs one extra capture: a non-main window
resolves the hue-suppressed tint matrix, so store the Main-context matrix per
cell with `setTintMatrix(_:for:)`, captured via
`GlassMaterialStyleAtlas.captureTintMatrix(from:)` at tint-selection time —
the user picks the color in an active window, which is exactly the
participation the matrix needs. Strength then drives alpha as
`sourceAlpha × value²` on the captured hue. The matrix is bound to the color
it was resolved for: after `tintColor` changes, the hue falls back to the live
(suppressed) resolution until the new color's matrix is captured and the
atlas refrozen.

`unfreeze()` returns to live behavior at the next rebuild. One caveat is
inherited from an open research question: whether AppKit writes an
intermediate Recipe during active/inactive transitions before the restamp runs
(roadmap P2). `GlassMaterialEffectView` refreshes on window main/key,
application activation, and appearance notifications, plus a follow-up
main-actor job — this covers the common orderings but does not establish a
deterministic final writer until that question is settled by capture.

## Take it

Copy this directory. It has no dependency on the rest of Liquid Glass Lab —
four files, AppKit only:

| File | Role |
|---|---|
| `GlassMaterialAccess.swift` | The minimum private-API surface: layer lookup, filter read/write, render bounds, rim gate/payload, color matrices |
| `GlassMaterialCurve.swift` | The measured curve: shapes, channel table, baseline |
| `GlassMaterialAtlas.swift` | The captured style atlas: appearance × variant × participation × size samples, Codable, interpolated |
| `GlassMaterialStrength.swift` | The controller and the `NSGlassEffectView` subclass |

## How it works

Endpoints are **read from the live Recipe**, never hard-coded. Each channel
resolves as:

```text
value(g) = start + (endpoint - start) × shape(g)
```

That is why size, appearance, Regular/Clear, window participation, and
subvariant all follow automatically: the system already resolved the right
endpoint for the current context, and `g = 1` reproduces it by construction.
This statement is exact at the 200pt reference geometry. At 48pt, SwiftUI
briefly uses a different adaptive face grade at the Materialize animation
endpoint before settling back to the static Recipe; that two-endpoint exception
is called out below.

`refresh()` distinguishes a replacement filter from the controller's own
near-1 write using the filter identity and last authored face opacity. If the
current Variant has no `glassBackground`, it clears the cached baseline and
reports `isAvailable == false` instead of carrying an endpoint over from the
previous Variant.

One update resolves the filter name and `inputKeys` capability set once, then
reuses that target for every channel. Tint matrix writes are capability-guarded
and disable implicit Core Animation actions just like background and Rim
writes.

What remains authored is only five dimensionless shapes:

```text
linear         g
quadraticFlat  0.2g + 0.8g²                 blur opacity 1/2, no Main
quadratic      0.4g + 0.6g²                 blur opacity 1/2 with Main, and 3/4
height         g + c·g(1-g)                 the shadow-height family
clamp          (0.34g + 0.036g²) / 0.376    Clear's inputClamp
```

`c` is `min(0.2, 16 / shortSide)`. Materialize inflates the SDF element's short
side by `min(0.2 · shortSide, 16)` points and retracts it with the outer
transaction. That View Envelope clock is distinct from face-opacity `g`, even
though the two are close in a one-second linear capture.

## What is verified

Measured on **macOS 26.6 (25G5065a)** and **macOS 27.0 (26A5388g)** for public
**Regular and Clear** in a panel, served by one table with no version branch.
Each accepted direct archive contains 104 runs / 936 samples across
appearance, backdrop, participation, tint, both directions, and `shortSide`
48/200/400. Fixtures and analysis live in `Golden/macOS-26/unified/`,
`Golden/macOS-27/unified/`, and the P1.1 section of
`Documentation/GlassResearchRoadmap.md`.

The executable learnings currently pass 33/33 on macOS 26. At the 200pt
reference size the single-endpoint curve replays the measured continuous
channels; across 48/200/400 every remaining channel stays inside the documented
geometry bound. A resize/rebuild test confirms the authored strength survives
AppKit replacing the whole subtree.

## What is not

- **macOS 27's compact visual acceptance is pending.** The direct macOS 27
  archive (`Golden/macOS-27/unified/`) landed: of its 22 new `glassBackground`
  inputs, 17 animate and are in the table, one is verified static, and the
  four aberration inputs never resolve in the sampled domain. The numeric side
  is closed from the same table as macOS 26; the targeted author review of the
  small-size path has not happened yet.
- **Private semantic roles and non-panel hosts** were never sampled.
- **Visual acceptance is the author's, not instrumented**, and only on macOS 26.
- **Runtime cost is unmeasured.** Do not drive this from a high-frequency
  update loop without profiling first.

## Known limits

Three behaviors are discrete by measurement and cannot be smoothed: the rim
gate opens at any `value > 0`; `inputSDRHoldingToneEnabled` adopts its Recipe
value at any `value > 0`; and Clear in DarkAqua steps
`inputBleedDarkenBlend` at `0.5`.

Mid-transition accuracy degrades away from a ~200pt short side, bounded by
`min(5%, 4 / shortSide)` — 5% at 48pt, 1% at 400pt, shrinking above that. The
cause is that a channel pinned to a cap stops tracking the inflating geometry
and reads as linear, and which channels are capped depends on size.

There is one separate exception: at 48pt, removal traverses both the long-lived
static Recipe and a different Materialized face grade. A single captured
baseline therefore cannot exactly replay `inputFaceColorMatrixBlack` and
`inputFaceColorMatrixWhite` for that path. The curve remains monotonic and
exact at its chosen static endpoints, but matching that compact transition
requires a future dual-endpoint adaptive face-grade model.

Setting `value = 1` does not uninstall the override. Restoring the true system
material requires a fresh `NSGlassEffectView`.

## Stability

This drives private CALayer filter and SDF-effect state. Every access is
selector- and `inputKeys`-guarded, so a renamed or removed key degrades to
"channel not written" rather than a crash — but a macOS release can still change
the curve itself. Re-run the fixtures in `Golden/` against a new OS before
shipping on it.
