# AppKit Glass Reverse Engineering

This document records measured behavior of macOS `NSGlassEffectView`: private
Recipe axes, resolver context, formulas, layer/filter payloads, mutation
contracts, probes, and platform scope. Everything described here uses
private implementation details and may change between macOS builds.

For the Liquid Glass Lab window controller, UI state, Live Inspector, Overrides,
knob organization, refresh model, and exporter, see
[Glass Lab Playground](./GlassLabPlayground.md).
For prioritized open questions, hypotheses, experiment protocols, and Material
Strength work, see
[Glass Research Roadmap](./GlassResearchRoadmap.md).

## Test environment

- Primary Recipe analysis: macOS 27.0 beta build `26A5378n` with the Xcode 27
  beta SDK
- macOS 27 Recursive Pass Audit: build `26A5388g`
- Cross-version Golden: macOS 26.6 build `25G5065a`
- `NSGlassEffectView` hosted directly in AppKit windows
- Integer resolver dispatch cases: `0...20`
- Known named subvariants: `menu`, `sheet`, `camera`

## Version scope

The public API begins at macOS 26, but private recipes, class names,
inventories, and ranges must not be treated as version-stable. Sections without
an explicit macOS 26 label describe the macOS 27 beta baseline. A macOS 26.6
Recipe Matrix and fixed-geometry Recursive Pass Audit now exist. The matching
macOS 27 audit is accepted on the fixture-level build above; preliminary
pass-family parity is recorded below, while value-level semantic classification
remains open.

Unknown Objective-C KVC keys raise `NSUnknownKeyException` before Swift can
catch them. Consumers must discover and guard private capabilities rather than
assuming that a later or earlier build exposes the same object graph. The
Playground's concrete fail-closed policy is documented separately.

## Runtime findings

### AppKit raw variants are not semantic roles

`NSGlassEffectView._variant` is an AppKit Recipe selector. The measured macOS 27
dispatch range is `0...20`; out-of-range values retain through the getter but
resolve like raw Variant 0. It must not be populated with ordinals from either
SwiftUI `_Glass.Variant.Role` or
`DesignLibrary.GlassMaterialProvider.Variant`.

Those two semantic enums each currently have 24 cases, but their names and
orders differ from one another and from AppKit. Passing a semantic ordinal to
`set_variant:` can appear to work through accidental overlap or Variant-0
fallback without selecting the named semantic treatment. The SwiftUI pipeline,
role table, shared base-Recipe mappings, and composite pass behavior are
documented separately in
[SwiftUI Glass Reverse Engineering](./SwiftUIGlassReverseEngineering.md).

### Variant is not the complete material recipe

`_variant` and `_subvariant` choose a material family, but the values finally
written to the `glassBackground` `CAFilter` also depend on the rendering
environment in which the view is resolved. The same state and geometry produce
different filter inputs in controlled active and neither-key-nor-main window
contexts.

Overriding the panel's `isKeyWindow` getter to return `true` does not change its
recipe. Therefore the decision is not based only on a virtual call to
`NSWindow.isKeyWindow`.

The controlled window matrix isolates the discriminator to real AppKit window
participation: a window that is genuinely key **or** genuinely main receives the
active recipe; a window that is neither receives the flat recipe. This is an
internal environment state, not the value returned by an overridden getter.

### Variant and subvariant are orthogonal state, but sparsely consumed

The original 426-sample sweep was not a Cartesian product: it sampled the
integer variants with `subvariant = nil`, then sampled the three names only on
Variant 0. A dedicated axis probe corrected that omission.

- The runtime has distinct integer dispatch cases for every value in `0...20`.
  Variants 16, 17, 18, and 20 were missing from the original test list.
- Other tested integers (negative values, `21...255`, 256, 511, 1024, 4096,
  65535, `Int32.max`, and the `Int` extrema) remain visible through the getter
  but resolve to the Variant-0 recipe.
- `_variant` and `_subvariant` are independently stored. Across all 63 named
  combinations, setting Variant then subvariant versus subvariant then Variant
  produced zero state or output mismatches.
- The resolver does not globally let the name "win." It conditionally consumes
  the named axis, and that consumption is itself context-dependent. For the
  0/1/12 base family, all three names change the flat recipe; in the active
  context, `menu` aliases the nil recipe while `sheet` and `camera` change it.
  On Variant 2, all three names change the base recipe but collapse to one
  shared named output in both contexts. On the other tested variants, the
  names do not change output.
- Names are case-sensitive. The property stores arbitrary strings, but the
  tested empty, uppercase, whitespace-suffixed, unknown, `popover`, `hud`,
  `window`, `toolbar`, and `alert` candidates had no effect. Three known names
  therefore means observed, not proven exhaustive.

At 480 × 200, considering Shader + Rim values, the accepted active context has
14 base signatures and 17 signatures across all 84 recipe cells. Its shared
base groups are `0/1/12/16`, `2/7/8`, `17/18`, and empty `13/14`. The accepted
flat context has 15 base signatures and 19 signatures across all
cells: Variant 16 is distinct there, while the other shared groups remain.
Including layer geometry adds one signature in each context because Variant 13
has no output effect while Variant 14 retains an output effect (`minimum =
-10000`, `maximum ≈ 3.3`) despite having neither Shader nor Rim pass. Thus the
full-payload totals are 18 active-context and 20 flat-context signatures.

This still is not the entire state space. Application activation, `shortSide`,
subdued/scrim state, adaptive appearance, tint color/opacity, and display
headroom can also affect resolved inputs. The key recipe branch is more
accurately `realKey || realMain`, not simply a `main` Boolean.

### Runtime resolution path

Static disassembly shows that `_variant`, `_subduedState`, `_scrimState`, and
related setters contain no shader arithmetic. They rebuild or invalidate an
`_NSGlassEffectViewMaterialContext` and enter a shared update path.

A breakpoint on `-[CAFilter setValue:forKey:]` captured the downstream path:

```text
NSGlassEffectView state / _NSGlassEffectViewMaterialContext
    -> SwiftUICore SDFLayer.updateSDFEffects
    -> SwiftUICore GraphicsFilter.makeCAFilter
    -> SwiftUICore _AnyCAFilterProvider.resolve(in:)
    -> DesignLibrary DLCAFilter
    -> QuartzCore CAFilter glassBackground inputs
```

For a default 480 x 200 glass, the write of `inputBleedAmount = 70` occurs at
the end of this path. This agrees with the measured formula
`0.35 * min(width, height)`.

The GPU implementation is a general RenderBox Metal function named
`glassBackground_v1`. Variant-specific numbers are resolved before the filter
is encoded; they are not separate hard-coded variant shaders.

### Geometry input is the shortest side

For the numeric recipe parameters that respond to size, the independent
variable is:

```text
shortSide = min(glassWidth, glassHeight)
```

Width and height sweeps produce the same values whenever `shortSide` matches.
Corner-radius sweeps changed none of the 66 numeric shader inputs or 13 captured
rim-highlight values. Corner radius instead changes the SDF/path geometry.

Representative default-family formulas include:

```text
inputBleedAmount           = 0.35 * shortSide
inputBleedHeight           = 0.35 * shortSide
inputBlurDistance0         = -0.50 * shortSide       (active key/main branch)
inputInnerRefractionAmount = -0.50 * shortSide, capped at -60
inputInnerRefractionHeight = 0.25 * shortSide, capped at 20
inputOuterRefractionAmount = floor 16, then 0.25 * shortSide (active branch)
inputOuterRefractionHeight = floor 16, then 0.20 * shortSide (active branch)
```

Across all valid recipe/context groups, every observed numeric size relation
fit one of these classes within the sampled points:

- constant
- proportional
- linear
- linear then plateau
- plateau then linear
- clamped linear

No remaining nonlinear group was found.

### Active and flat contexts receive materially different recipes

At Variant 0 and 480 x 200, the important differences are:

| Parameter | Active | Flat |
|---|---:|---:|
| `inputBleedBlurRadius` | 70 | 0 |
| `inputBleedOpacity` | 0.8 | 0 |
| `inputBlurDistance0` | -100 | 0 |
| `inputOuterRefractionAmount` | 50 | 0 |
| `inputOuterRefractionHeight` | 40 | 0 |
| `inputRefractionOpacity` | 0.6 | 0 |
| `inputShadowOpacity` | 0.6 | 0 |
| `inputShadowRadius` | 24 | 0 |
| Rim layer opacity | 1 | 0 |
| Rim key/fill color alpha | 1 | 0 |

The layer geometry differs as well:

| Geometry | Active | Flat |
|---|---:|---:|
| `CABackdropLayer.marginWidth` | about 70 | about 0.5 |
| `CASDFOutputEffect.maximum` | about 39.8 | about 1.5 |

Across the full accepted sweep, `marginWidth` reached 168 at sampled
`shortSide = 480`; its same `0.35 × shortSide` relation gives a Recipe maximum
of 210 over the lab's 600-point domain. `CASDFOutputEffect.maximum` capped at
about 39.83, so its close Recipe range is `0...40`. The lower bound remained
the discrete `-10000` sentinel wherever the output effect existed.

Consequently, the flat result is not merely the active material without focus.
Outer refraction, bleed, shadow, ring shadow, and the rim pass are disabled or
bounded to almost no exterior SDF reach, while several blur-gradient weights
are changed to a flatter treatment.

### The selected branch follows real key-or-main participation

A signed app-bundle probe held process activation, recipe, size, backdrop, and
content constant while varying 19 window conditions. The resolved values formed
exactly two clusters:

- Five genuinely key conditions produced one identical active recipe.
- Fourteen conditions that were neither key nor main produced one identical
  flat recipe.

Changing these properties did not directly change the recipe:

- `NSWindow` versus `NSPanel`
- titled versus borderless
- presence of `.nonactivatingPanel`
- `canBecomeKey` while the window remained non-key
- opaque versus transparent
- native window shadow on versus off
- normal versus floating window level

A `.nonactivatingPanel` subclass with `canBecomeKey = true` received the full
active recipe as soon as it became genuinely key. Conversely, a titled,
key-capable `NSWindow` received the flat recipe while another window was both key
and main.

A second isolation pass separated key status from main status:

| Condition | Real key | Real main | Recipe |
|---|---:|---:|---|
| Titled `NSWindow` | no | yes | Active |
| Non-activating `NSPanel` | yes | no | Active |
| Non-activating HUD `NSPanel`, `canBecomeKey = false` | no | yes | Active |

These three conditions had zero differences across all 66 numeric shader
inputs, 13 rim values, and captured layer geometry. Within the tested
active-process environment, real key status and real main status are
independently sufficient; being neither is sufficient for the flat branch.

The exact Panel main-only sample used `canBecomeKey = false` and
`canBecomeMain = true`, kept another window genuinely key, and called
`makeMain()`. The panel became `NSApplication.mainWindow` without becoming key
and resolved margin 70, SDF reach about 39.8, outer refraction 50/40, bleed
opacity 0.8, shadow opacity 0.6, and a fully enabled rim. Main participation
alone is therefore sufficient even for the production HUD's class and style.

`canBecomeKey` therefore matters indirectly: the production HUD panel forbids
both key and main participation, so it can never enter the active branch.
Spoofing `isKeyWindow` and posting the public key notifications does not change
the internal AppKit/WindowServer state and leaves the panel on the flat branch.

Giving the HUD real main status is technically a way to obtain the active
recipe without keyboard focus, but it also moves AppKit's main-window semantics
away from the content window. That can affect command routing, responder-chain
behavior, window appearance, and restoration, so recipe cloning remains the
lower-side-effect visual transplant.

### Subdued suppresses the active Shader/Rim payload but is not a Main alias

A controlled `Main × Subdued` pass kept the application active and used the
transparent Panel at 480 × 200, corner radius 16, nil subvariant, no tint,
default adaptive appearance, and no overrides. It verified actual key/main
identity for every sample and compared 84 report fields spanning the
`glassBackground` inputs, Rim projection, and captured layer geometry. Variant
0 and Variant 2 were tested independently.

| Real main | Subdued | Observed result |
|---:|---:|---|
| no | no | Flat payload |
| no | yes | Same flat payload; Subdued made no measured change |
| yes | no | Active payload |
| yes | yes | Flat Shader/Rim payload; geometry can remain context-sensitive |

For the tested Shader and Rim fields, the effective gate can be summarized as:

```text
usesActiveShaderAndRim = (realKey || realMain) && !isSubdued
```

This is an output model, not proof that the stripped resolver implements one
literal Boolean expression. `_subduedState` is an independently stored recipe
axis; the downstream resolver can coalesce its output with the flat
window-participation payload.

Variant 2 coalesced completely: neither + normal, neither + subdued, and
main-only + subdued had zero differences across all 84 compared fields.
Main-only + normal was the sole active payload.

Variant 0 exposed why Subdued cannot simply be renamed `Main = false`.
Main-only + subdued matched the flat Shader, Rim, and SDF reach, but retained a
different `CABackdropLayer.marginWidth`: 16 instead of the neither-window value
0.5. Main-only + normal resolved margin 70 and SDF maximum about 39.83; the
subdued main-only sample resolved maximum 1.5, like the flat payload. Thus this
condition is a hybrid environment: the material face is flat while at least
one render-bound value still knows about real window participation.

The accepted historical matrices held Subdued false. A fully orthogonal
`Main × Subdued × Variant × Subvariant` audit requires 336 contexts per Host
Type before adding Scrim, appearance, tint, size, or activation axes.

### Rim highlight is a separate, recipe-dependent pass

The visible edge highlight is a `CASDFKeyFillHighlightEffect` on a separate
`CASDFLayer`. Variants and subvariants can change its curvature, heights,
spreads, and angles. The active-versus-flat environment branch primarily changes
its layer-opacity gate and key/fill color alphas.

Observed system-recipe values include:

| Attribute | Observed range |
|---|---:|
| `keyHeight`, `fillHeight` | 0.75...3.5 |
| `keySpread` | 0.872665...2.0944 |
| `fillSpread` | 0.872665...1.5708 |
| `keyAngle` | 0...0.436332 |
| `curvature` | 0.7...1 |
| `diffuseAmountScale` | 0.15 |
| `diffuseHeightScale` | 8 |
| `diffuseSpreadScale` | 0.65 |
| key/fill height and spread scales | 1 |
| key/fill height and spread offsets | 0 |
| `global` | false |

Core Animation metadata publishes `0...50` for key/fill height even though the
observed recipes use 0.75...3.5. It also publishes `0...1` for
`diffuseHeightScale`, even though live recipes resolve 8. Generic authoring
metadata therefore does not necessarily describe the system Recipe envelope.

### Missing compact-inspector passes are intentional recipe results

- Variants 13 and 14 have no `glassBackground` filter in either context.
- Variants 4, 13, and 14 have no `CASDFKeyFillHighlightEffect` pass.

An unavailable live value for these combinations is not a sampling failure.
It also does not mean that the complete recursive tree has no other pass: the
macOS 26 audit below demonstrates that Variant 14 is the strongest example of
that distinction.

### macOS 26.6 recursive pass inventory

The accepted fixed-geometry audit on build `25G5065a` captured all 336
`Main × Subdued × Variant × Subvariant` rows at 480 × 200 with no inactive,
participation-mismatch, or missing-tree samples. It produced nine topology
signatures and 63 resolved-value signatures.

A common Recipe tree contains 16 layers and five pass/effect objects, including
two `vibrantColorMatrix` filters and a `CASDFOutputEffect` that the compact
first-backdrop/first-rim Inspector did not inventory. Recursive traversal also
found `CASDFFillEffect`, `CASDFGradientEffect`, `CASDFShadowEffect`,
`CASDFGlassHighlightEffect`, `CASDFGlassDisplacementEffect`, `displacementMap`,
and `glassForeground` families.

Variant 14 contains 23 layers and 11 pass/effect objects despite having neither
compact-inspector pass. Its tree includes an `SDFPortalLayer`-owned
`glassForeground`, two `CASDFGlassHighlightEffect` objects, a shadow, a
gradient, and `plusD`/`plusL` compositing filters. Variant 19 contains 21 layers
and nine pass/effect objects, including `glassBackground`, `displacementMap`,
`glassForeground`, and `CASDFGlassDisplacementEffect`. Variant 5 uses the
`screenBlendMode` compositing filter.

The two observed `glassForeground` instances publish 13 inputs. Both explicitly
populate Aberration/Refraction fields: for example, Variant 14 resolves
`inputAberrationHeight ≈ 3.3`, `inputAberrationAngle = π/2`,
`inputRefractionHeight = 8`, and `inputRefractionOffset ≈ -3.3`, while its
`inputAberrationAmount` is zero. These client-side values establish a separate
foreground pass and authored private knobs, not their visual contribution. The
corresponding pass family is present in the macOS 27 audit below.

Subvariant changed no topology in any of the 84 fixed-geometry base groups. It
changed resolved values for Variants 0, 1, 2, 4, 7, 8, 10, 12, and 16, exactly
matching the 480 × 200 slice of the compact Recipe Matrix. The Height 24 Matrix
additionally selects Variants 9, 15, 17, 19, and 20 for targeted compact replay.

### macOS 27 recursive pass inventory

The accepted fixed-geometry audit on build `26A5388g` captured the same 336
`Main × Subdued × Variant × Subvariant` rows at 480 × 200. All rows were active,
requested and actual Main participation matched, actual key remained false,
and every snapshot contained a layer tree. The capture produced eight topology
signatures and 60 resolved-value signatures.

An immediate repeat in the same display session reproduced every row,
signature, layer payload, pass inventory, and nonvolatile property value; only
the top-level capture timestamp changed. An earlier capture around a display-
context transition retained the same topology, layers, and pass inventory but
changed three resolved fields across 268 rows:

- `CASDFOutputEffect.maximum` changed in 154 rows;
- `DLCAFilter` `glassBackground.inputKeyFillHighlightEffectOffset` changed in
  268 rows;
- `DLCAFilter` `glassBackground.inputKeyFillHighlightHeight` changed in 212
  rows.

Typical transitions were `maximum: 2 → 1.5`, highlight offset `-1 → -0.5` or
`-2 → -1`, and highlight height `1 → 0.5`. This establishes display/runtime
sensitivity for those resolved values; it does not establish which display
metric drives them. The contrast capture remains alongside the canonical and
same-context repeat as provenance.

The macOS 26 and macOS 27 documents use different whole-tree wrappers, so raw
structural paths cannot be treated as semantic identities across releases.
Matching by Recipe axes and normalized pass family gives this preliminary
inventory result:

- macOS 27 retains the observed `glassForeground`, displacement, highlight,
  gradient, shadow, fill, output, key-fill, color-matrix, `plusD`, and `plusL`
  families;
- Variant 5 is the only current family-level exception: all 16 of its rows lose
  `CASDFFillEffect` and `screenBlendMode`, reducing the pass count from seven to
  five;
- `glassBackground` remains in 304 rows, but its client object class changes
  from `CAFilter` to `DLCAFilter` and it publishes 22 additional input keys;
- key-fill effects add `diffuseAmountScale`, `diffuseHeightScale`, and
  `diffuseSpreadScale` attributes;
- the largest topology outliers remain recognizable: Variant 14 still contains
  11 passes and Variant 19 still contains nine.

The 22 additional `glassBackground` keys cover foreground aberration,
blur-fill, face-matrix, key-fill-highlight, and ring-shadow controls:

```text
inputAberrationAmount / inputAberrationAngle / inputAberrationHeight
inputAberrationOffset
inputBlurFillBlurRadius / inputBlurFillDarkenOpacity
inputBlurFillLightenOpacity / inputBlurFillNormalOpacity
inputFaceColorMatrixMaxLuma / inputFaceColorMatrixMaxLumaSDR
inputKeyFillHighlightAmount / inputKeyFillHighlightAngle
inputKeyFillHighlightColorBias / inputKeyFillHighlightEffectOffset
inputKeyFillHighlightHeight / inputKeyFillHighlightSpread
inputKeyFillHighlightSpreadSDR
inputRingShadowBlurRadius / inputRingShadowMask / inputRingShadowOffset
inputRingShadowOpacity / inputRingShadowStrokeWidth
```

These are client-side class, capability, placement, and value observations.
They do not prove a renderer implementation change or visual contribution.
Value-level classification and controlled mutation remain required before the
cross-version delta is considered closed.

### Complete attribute inventory

The current `glassBackground` filter publishes 77 input keys:

- 72 `NSNumber` inputs, including values whose metadata subtype is `bool`,
  `percentage`, or `angle`.
- 3 `CGColor` inputs: face, bleed, and shadow fill color.
- 1 `NSValue` point: `inputShadowOffset`.
- 1 `NSString`: `inputSourceSublayerName`, exposed read-only because it names a
  layer-tree dependency rather than a numeric material parameter.

Sixty-six numeric inputs are populated by at least one sampled recipe. Six are
currently declared but nil: `inputBlurOpacity4`, `inputBlurDistance4`,
`inputAberrationAmount`, `inputAberrationHeight`, `inputAberrationOffset`, and
`inputAberrationAngle`. No sampled system Recipe populates them.

`CASDFKeyFillHighlightEffect.CA_attributes` publishes 23 attributes: 21
numeric/Boolean values and 2 full colors. The owning layer has a separate
opacity gate, and the key/fill color alphas can be projected independently.
The complete scale/offset/global inventory includes:

```text
keyHeightScale / keyHeightOffset / keySpreadScale / keySpreadOffset
fillHeightScale / fillHeightOffset / fillSpreadScale / fillSpreadOffset
diffuseHeightScale / diffuseSpreadScale / global
```

Finally, the captured layer geometry contains three values:
`CABackdropLayer.marginWidth`, `CASDFOutputEffect.minimum`, and
`CASDFOutputEffect.maximum`. `minimum = -10000` is a Recipe sentinel, while its
published authoring range is `-200...0`.

## Private mutation contracts

Every observed private mutation path has a non-obvious contract; violating it
silently no-ops or crashes.

- `glassBackground` inputs: filter objects attached to a layer are immutable.
  Writes must go through the layer as
  `layer.setValue(_, forKeyPath: "filters.glassBackground.<inputKey>")`.
- SDF effects (`CASDFKeyFillHighlightEffect`, `CASDFOutputEffect`, ...) behave
  as value objects: mutate a copy and reassign it to the layer's `effect`.
  In-place mutation of the installed effect is ignored.
- CGColor-typed effect properties (`keyColor`, `fillColor`) cannot be boxed by
  KVC; they require typed `@convention(c)` IMP calls for both read and write.
- `CABackdropLayer.marginWidth` accepts plain KVC.
- The rim gate is system-animated: a leftover named or grouped property
  animation can pin the rendered value regardless of the model write. Stamping
  removes animations targeting `opacity`, `effect`, or an `effect.*` key path
  inside a no-actions `CATransaction`.
- Private setters trap on out-of-range values: `_adaptiveAppearance` and
  `_interactionState` accept `0...2` and hit Swift preconditions at 3+
  (`NSGlassEffectView` is implemented in Swift inside AppKit). Every entry
  point is selector-guarded and clamped.
- The system re-resolves the recipe on environment and geometry changes and
  can replace the complete filter/effect layer subtree after the setter
  returns. A transplant must re-stamp after every explicit resolution and at
  the end of the replacement glass's internal layout pass. Fixed-delay writes
  alone cannot establish a deterministic final writer.
- The inverse is asymmetric: stopping writes does not remove an installed
  `glassBackground` override. Same-Recipe setter bounces preserve the mutated
  CAFilter; even an empty Variant-13 bounce rebuilt Rim and Geometry but left
  the Shader value installed. Restoring the system Recipe therefore requires a
  fresh `NSGlassEffectView`/private filter tree rather than merely stopping
  writes. A runtime probe verified Shader `5 → 123 → 5`, Rim
  `0.5 → 0.9375 → 0.5`, and SDF maximum `2 → 123 → 2` across replacement.

## Complete transplant checklist

Cloning the active recipe onto a neither-key-nor-main window requires four
groups; each was individually observed to be necessary:

1. All populated numeric `glassBackground` inputs (66 on this build), the
   three fill colors, and `inputShadowOffset`. The source-layer string is
   diagnostic/read-only.
2. Layer geometry: `CABackdropLayer.marginWidth` and both
   `CASDFOutputEffect.minimum` / `maximum`. Without them the transplanted outer passes
   hard-clip at the outline — the "clipped ring" artifact.
3. The rim pass: layer opacity gate, all 21 numeric/Boolean effect values, and
   full key/fill colors (with alpha projections available separately).
4. Host-window room: a window's backing surface hard-clips everything at its
   frame (only the native WindowServer window shadow may draw outside it), so
   the glass must sit inset by at least `marginWidth` inside a transparent
   window.

Because the size-scaled inputs follow the measured `shortSide` formulas,
transplant values can either be captured from a live donor with matching
`shortSide` or computed directly from the formulas.

## Adjacent observations

- Real system menus resolve as Variant 0 plus subvariant `menu`. The axes are
  independently stored; recognized names are conditionally consumed for some
  Variant families rather than globally overriding the integer.
- The Music mini-player material is a clear-family variant plus a deep,
  mostly opaque public `tintColor`; no variant alone reproduces it.
- `NSVisualEffectView` (`.menu`, `.popover`, `.hudWindow`) still runs the
  classic pipeline — `gaussianBlur` radius ~30 plus `colorSaturate` ~2.2 —
  not `glassBackground`.
- Light/dark adaptation happens in the render server through
  `vibrantColorMatrix` filters with `inputBackdropAware = 1`; it never
  appears in model-side values. `_adaptiveAppearance` 0/1 pins the mode, 2 is
  adaptive.
- Observed variant clustering has two useful levels. Visual families remain
  Default, Clear-like, lens-like, and shadowed treatments. Exact Shader/Rim
  payloads group 0/1/12/16 when active but only 0/1/12 when flat; both contexts
  also group 2/7/8, 17/18, and empty 13/14. Geometry separates 13 from 14.
  Variant 4 remains notable for keeping `glassBackground` while dropping the
  rim pass.
- The SDF effect family contains more passes than the glass composes today:
  `CASDFShadowEffect` (color/radius/offset/punchout/invert),
  `CASDFGradientEffect`, `CASDFGradientContourEffect`, and
  `CASDFVisualizationEffect` all exist in the runtime.

## Notes for a production HUD

- A borderless, non-activating HUD panel with `hasShadow = false`, sized exactly
  to its content, can place the glass at zero margin and clip it with a sibling
  continuous-corner mask. Two structural changes are prerequisites for the
  active recipe to render fully there: the panel needs a transparent margin of
  at least `marginWidth` (70 at current sizes), and the continuous clip mask
  must stop cutting the glass at the content outline — the outer passes render
  beyond it by design.
- Dragging, fling, and edge-snapping currently use the panel frame; with a
  margin they must switch to the visual (card) frame, and hit-testing must
  ignore the transparent border.
- `makeMain()` on the panel is the zero-transplant alternative, but it moves
  main-window semantics off the content windows (command routing, responder
  chain, restoration). Recipe cloning remains the lower-side-effect option.

## Dead ends (do not retry)

- Spoofing `isKeyWindow` and posting the public key notifications: no recipe
  change (see the window matrix).
- Screen EDR headroom as the branch discriminator: `CASDFOutputEffect.maximum`
  was initially suspected of snapshotting display headroom, but it ignores
  `preferredDynamicRange`, style-mask, opacity, and geometry changes — it is
  the SDF reach clamp.
- `_adaptiveAppearance` as the source of the active/flat difference: pinning
  it changes light/dark treatment only, never the branch.

## Sampling performed

The historical geometry/formula sweep contains 426 samples covering:

- 17 integer variants (`0...15`, 19) with nil subvariant, plus three named
  subvariants on Variant 0 — this is why it must not be described as orthogonal.
- Canvas and HUD-panel contexts.
- height points from 24 through 600 with width fixed at 480.
- width points from 60 through 900 with height fixed at 200.
- corner radii from 0 through 80.

Canvas samples were accepted only after confirming that the application was
active and the Canvas window was genuinely key. All 426 captured conditions
retained the expected active-Canvas versus neither-key-nor-main HUD split. The
sweep directly samples `shortSide` through 480; formula-derived bounds at 600
are extrapolated only from zero-error linear or piecewise fits.

A separate axis audit scanned integers `0...255` plus negative and extreme
values, then evaluated all `21 × 3 = 63` named combinations in both setter
orders. It established the `0...20` dispatch domain, order independence, sparse
subvariant consumption, and exact-signature groups described above.

A preliminary follow-up correctly rejected its results when the desktop
display/session was asleep: it reported `appActive = false` and no real key
window. After the session was unlocked with the display awake, the signed probe
was rerun and accepted 1008 records across all 84 recipe cells, six heights
(`24, 60, 100, 200, 400, 600` with width 480), and two hosted surfaces.

The accepted run began with `appActive = true`, the Canvas as the actual key
and main window, and the Panel as neither. All 504 Canvas rows retained
`isKeyWindow = true`; all 504 Panel rows retained `isKeyWindow = false`. It
therefore closes active Canvas and active-application HUD coverage for Variants
16, 17, 18, and 20 as well as the full Variant/subvariant product. Across that
domain, the observed Shader ranges fit the already established constant,
linear, and capped-piecewise classes; no new range class appeared.

A separate signed app-bundle probe captured 19 controlled window conditions,
then two simultaneous key-only/main-only conditions. Every accepted sample
verified `NSApplication.isActive`, `NSApplication.keyWindow`, and
`NSApplication.mainWindow` instead of trusting the requested state or an
overridden window getter.

A later interactive `Main × Subdued` audit captured four accepted contexts for each
of Variants 0 and 2 on the Panel at 480 × 200 and compared 84 report fields per
context. It established the Shader/Rim suppression gate, Variant 2's complete
flat-payload coalescence, and Variant 0's single retained main-dependent
`marginWidth` difference described above. This is eight accepted context
captures, not yet a sweep across all 84 Variant/Subvariant cells.

## Future research

Unresolved AppKit work is tracked centrally in
[Glass Research Roadmap](./GlassResearchRoadmap.md). It includes the Material
Strength curve, the declared-but-nil Aberration anomaly, complete pass/property
inventory, the remaining `Main × Subdued` matrix, inactive-app mutation timing,
value-level classification of the semantic macOS 26 versus macOS 27 recursive
report, and controlled mutation of newly observed properties.
