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

## Take it

Copy this directory. It has no dependency on the rest of Liquid Glass Lab —
three files, AppKit only:

| File | Role |
|---|---|
| `GlassMaterialAccess.swift` | The minimum private-API surface: layer lookup, filter read/write, rim gate, tint matrix |
| `GlassMaterialCurve.swift` | The measured curve: shapes, channel table, baseline |
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
side by `min(0.2 · shortSide, 16)` points and retracts it linearly with `g`, so
geometry-tracking channels inherit that as a quadratic term.

## What is verified

Measured on **macOS 26.6 (25G5065a)** for public **Regular and Clear** in a
panel, across appearance, backdrop, participation, tint, and both directions —
64 runs / 576 samples, plus a 12-run geometry sweep at `shortSide` 48/200/400.
Fixtures and analysis live in `Golden/macOS-26/` and the P1.1 section of
`Documentation/GlassResearchRoadmap.md`.

Replay accuracy is 41 of 42 channels within 0.1% at a ~200pt short side. A
resize/rebuild test confirms the authored strength survives AppKit replacing the
whole subtree.

## What is not

- **macOS 27 is unvalidated.** Its `glassBackground` is a `DLCAFilter` with 22
  additional input keys. Keys absent from the channel table are never written,
  so if any of them animate, `value = 0` will not be clean there.
- **Private semantic roles and non-panel hosts** were never sampled.
- **Visual acceptance is the author's, not instrumented**, and only on macOS 26.
- **Runtime cost is unmeasured.** Do not drive this from a high-frequency
  update loop without profiling first.

## Known limits

Two behaviors are discrete by measurement and cannot be smoothed: the rim gate
opens at any `value > 0`, and Clear in DarkAqua steps one bleed-blend flag at
`0.5`.

Mid-transition accuracy degrades away from a ~200pt short side, bounded by
`min(5%, 4 / shortSide)` — 5% at 48pt, 1% at 400pt, shrinking above that. The
cause is that a channel pinned to a cap stops tracking the inflating geometry
and reads as linear, and which channels are capped depends on size. **Endpoints
stay exact and the curve stays strictly monotonic at every size**, so the error
is a mid-transition rate difference, never an endpoint or ordering error.

Setting `value = 1` does not uninstall the override. Restoring the true system
material requires a fresh `NSGlassEffectView`.

## Stability

This drives private CALayer filter and SDF-effect state. Every access is
selector- and `inputKeys`-guarded, so a renamed or removed key degrades to
"channel not written" rather than a crash — but a macOS release can still change
the curve itself. Re-run the fixtures in `Golden/` against a new OS before
shipping on it.
