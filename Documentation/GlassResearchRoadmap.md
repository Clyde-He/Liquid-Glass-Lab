# Glass Research Roadmap

This document is the ordered backlog for unresolved Glass research. Verified
runtime behavior belongs in the two Reverse Engineering documents; lab UI and
export behavior belong in the Playground document. An item remains here until
an accepted capture, controlled mutation, or runtime trace turns it into
evidence.

- [AppKit Glass Reverse Engineering](./AppKitGlassReverseEngineering.md)
- [SwiftUI Glass Reverse Engineering](./SwiftUIGlassReverseEngineering.md)
- [Glass Lab Playground](./GlassLabPlayground.md)

## Scope and execution order

The lab studies two Liquid Glass authoring paths available to a macOS
application:

- AppKit `NSGlassEffectView`, which resolves Recipe axes into a Core Animation
  layer/filter/effect composition;
- SwiftUI public `Glass` and private `_Glass`, which describe semantic intent
  and build a larger environment-dependent composition.

They are distinct authoring pipelines, not necessarily distinct rendering
engines. Both reuse SwiftUICore/Core Animation primitives downstream. Classic
`NSVisualEffectView` materials remain useful fallbacks but are outside this
investigation.

The new recursive evidence changes the dependency order. A common AppKit
Recipe contains five observed pass/effect objects and Variant 14 contains 11,
while the original editor controlled only the first `glassBackground` and
first key-fill highlight. A Material Strength curve designed against that
partial composition could misidentify visual responsibility or leave major
contributors untouched. Observed-pass completeness is therefore the enabling
work, not an optional refinement.

| Priority | Track | Current state |
|---|---|---|
| P0 | AppKit observed-pass completeness and control | Regular/Clear target topology closed: all five passes have accepted controls; V14/V19 outlier-family audits remain separate |
| P1 | Material Strength and system preset-curve research | Regular/Clear capture and curve model closed on **macOS 26 and 27** from one table with no version branch. macOS 26 author visual acceptance and resize reconstruction passed; targeted macOS 27 visual acceptance at the compact size remains. Of 27's 22 new inputs, 17 animate and are modelled, one is verified static, and four aberration inputs never resolve in the public dynamic domain. P1.4 cost also remains |
| P2 | Recipe-axis closure | Fixed macOS 26/27 products captured; targeted axes remain |
| P3 | Pass injection/transplant | Deferred, high risk, not required for Override |
| P4 | Broader SwiftUI private authoring | Role inventory and fixed-context trees complete |

“Complete” in P0 means complete for the observed `NSGlassEffectView` Recipe
domain and selected real system surfaces. It does not mean enumerating every
private QuartzCore/SwiftUICore class present in the operating system.

## P0 — AppKit observed-pass completeness and control

### Accepted foundation

The fixed-geometry macOS 26.6 audit on build `25G5065a` captured all 336
`Main × Subdued × Variant × Subvariant` rows at 480 × 200 with no inactive,
participation-mismatch, or missing-tree samples. It produced nine topology
signatures and 63 resolved-value signatures.

Recursive traversal found pass families outside the old first-backdrop/first-
rim contract: `vibrantColorMatrix`, `CASDFOutputEffect`, `CASDFFillEffect`,
`CASDFGradientEffect`, `CASDFShadowEffect`, `CASDFGlassHighlightEffect`,
`CASDFGlassDisplacementEffect`, `displacementMap`, and `glassForeground`.
Variant 5 uses the `screenBlendMode` compositing filter; Variant 14 uses `plusD`
and `plusL`. Variant 14 and Variant 19 are the strongest topology outliers.

The matching macOS 27 audit on build `26A5388g` also captured all 336 accepted
rows. It produced eight topology signatures and 60 resolved-value signatures.
An immediate same-display-session repeat was row-for-row identical apart from
the document timestamp. An earlier display-context contrast kept topology,
layers, and pass inventory stable but changed three resolved fields across 268
rows, so those fields remain environment-sensitive evidence rather than
cross-version Recipe constants.

The complete verified values and topology descriptions are maintained in the
AppKit Reverse Engineering document. The pass/property matcher is implemented;
the remaining work is value-level classification and safe control.

### P0.1 — Cross-version recursive classification

The same 336-cell fixed-geometry audit is now accepted on macOS 27. Raw
structural-path comparison is not sufficient because a whole-tree wrapper
changed between releases. The comparator now matches Recipe axes, groups by
pass channel/family, and pairs duplicate families using owner-path and property-
inventory similarity. Raw mode remains available for exact structural review.

Classify every difference as one of:

- pass added, removed, moved, duplicated, or renamed;
- input/attribute added, removed, renamed, nil, or newly authored;
- same topology with changed resolved value;
- client-side representation change with no established visual meaning;
- volatile environment value that must not enter a semantic signature.

The first semantic pass-family pass confirms that macOS 27 retains the observed
`glassForeground`, displacement, highlight, gradient, shadow, fill,
color-matrix, output, key-fill, and `plusD`/`plusL` families. Variant 5 is the
only current family-level exception: its 16 rows lose `CASDFFillEffect` and
`screenBlendMode`, reducing that tree from seven to five passes.

The `glassBackground` family remains present in 304 rows but changes from
`CAFilter` to `DLCAFilter` and publishes 22 additional input keys. Key-fill
effects add three diffuse scale attributes. These are client-side inventory
facts; their visual or renderer-level meaning still requires controlled
mutation. The matcher reduces the cross-version audit to 1,776 matched passes,
32 Variant-5 removals, 304 client-object class transitions, 25 property-
inventory additions, and an explicit value-difference inventory. Classify
those value changes and validate selected high-signal properties by controlled
mutation before closing this item.

### P0.2 — Recursive Pass Inspector

The first read-only stage is implemented. It reuses the accepted Recursive
exporter traversal, samples only while the Passes page is mounted, and
shows every observed pass with channel/family grouping, duplicate ordinals,
owner/object classes, raw structural locator, and declared property
state/value/metadata. The same snapshot supplies a raw Layer tree and copyable
deterministic report.

`Present`, `Overridden`, absent-target `Dormant`, and live-object `Replaced`
states are now explicit. Stable export IDs remain deterministic and do not
encode process addresses. A separate mounted-view tracker compares non-owning
`ObjectIdentifier` tokens by structural pass slot, latches `Replaced` on the
current token, pauses sampling off the page, and resets when the Renderer
changes. It never retains the private CAFilter/effect object.

Runtime acceptance distinguished value resolution from reconstruction:
Variant 0 → 1 retained all five pass identities and reported zero replacements,
while Panel → Window rebuilt the host and reported all five reference-backed
passes as `Replaced`. SwiftUI → NSGlass reset the tracker to a fresh zero state.

Current status against the acceptance checklist:

- [x] show every layer, mask-owned tree, filter, background filter, compositing
  filter, and object-backed effect;
- [x] group instances by stable structural locator, owning layer role/class, pass
  class/name, and ordinal where duplicates remain;
- [x] distinguish multiple instances of one class, such as Variant 14's two
  `CASDFGlassHighlightEffect` objects;
- [x] display declared capability independently from absent, nil, unreadable, and
  resolved values;
- [x] show `Present`, `Overridden`, and `Dormant` state explicitly;
- [x] track live object replacement and show `Replaced` without retaining a
  stale object reference;
- [x] retain a raw tree/report view even when a property is not yet editable.

Structural paths are diagnostic evidence, not permanent API. Cross-version
matching should prefer pass family, owner role/class, nearby topology, and
source dependency before falling back to an array index.

### P0.3 — Tune Existing Pass

The first editor controls only pass instances already produced by the current
Recipe. It does not create a pass that the resolver omitted.

Classify and implement each mutation family separately:

- CAFilter inputs: write through the owning layer's named filter key path;
- SDF effects: copy, mutate the copy, and reassign `layer.effect`;
- layer gates and geometry: mutate the owning layer with explicit no-animation
  behavior where appropriate;
- compositing filters: treat as discrete modes or read-only inventory, not a
  continuous slider;
- source-layer names and object dependencies: read-only until a controlled
  dependency experiment proves safe replacement;
- typed values: generate distinct numeric, Boolean, color, point, matrix, and
  string presentations rather than coercing every value into `Double`.

Core Animation metadata supplies type/range evidence but is not automatically
a safe Recipe range. Every editor family starts read-only and becomes writable
only after its mutation contract is accepted.

The first classification/editor-routing stage is implemented. Passes now gives
every live structural slot its own selection and page, including duplicate
families such as Variant 14's two Glass Highlights. It labels each pass as
CAFilter Inputs, SDF Effect Copy/Reassign, Compositing
Mode, or unknown/read-only. Properties receive distinct Numeric, Percentage,
Angle, Boolean, Color, Point, Size, Color Matrix, String, source/image
dependency, and typed-array presentations from the accepted metadata rather
than being coerced into `Double`.

Only previously validated mutation contracts are promoted: selecting
`glassBackground` mounts Glass Filter Override,
`CASDFKeyFillHighlightEffect` mounts Rim Override, and
`CASDFOutputEffect.minimum/maximum` mount Render Bounds on that pass page. Each
of the two structurally distinct `vibrantColorMatrix` filters mounts three
optional Boolean inputs plus its complete 4 × 5 Float matrix. The common
Regular/Clear five-pass topology therefore reports 109 accepted property
contracts out of 110; the remaining source-layer dependency string is
intentionally read-only. Variant 14's `glassForeground`, duplicate Glass
Highlights, Gradient, Shadow, and `plusD`/`plusL` remain read-only until their
separate outlier-topology work continues in P0.4.

Current status:

- [x] classify every observed pass by mutation family;
- [x] classify declared properties into distinct typed presentations;
- [x] expose every live pass instance as an independently selected page;
- [x] keep duplicate instances independently addressable by structural slot and
  ordinal;
- [x] expose accepted existing-pass routes without creating an absent pass;
- [x] keep dependencies, unaccepted composite arrays/matrices, and compositing
  modes explicitly read-only;
- [x] accept independently addressed typed writes for both common
  `vibrantColorMatrix` structural slots;
- [ ] accept controlled mutation contracts for the Variant 14 foreground,
  highlight, gradient, shadow, and compositing families;
- [ ] add independently addressed generic writes only for accepted contracts.

### P0.4 — Mutation contract audit

For each observed pass family, change one independent variable at a time and
record:

- model value before and after the write;
- presentation value and attached CAAnimation key paths;
- rendered before/after result against controlled diagnostic content;
- whether the object accepts live mutation, requires copy/reassign, or is
  replaced asynchronously;
- layer opacity, source dependency, or another gate that can make a successful
  write visually inert;
- safe reset behavior and whether the original Recipe can be reconstructed.

Prioritize Variant 14's `glassForeground`, two Glass Highlight effects,
Shadow, Gradient, and compositing modes, followed by Variant 19's displacement
chain. For `glassForeground` Aberration, compare nil where supported, explicit
zero, and a clearly nonzero value while Refraction and layer gates stay frozen.
Do not promote an Aberration knob into product control merely because it is
declared or accepts a value.

The first narrow `inputAberrationAmount` probe is implemented and has completed
the accepted fixed-context nil/zero/one readback experiment. All three requests
survived the 350 ms settling window in both model and presentation state; every
owning-layer write replaced the immutable CAFilter object, while owner opacity,
visibility, source `@0`, and the empty animation inventory stayed stable. A
fresh-tree reconstruction restored zero before every run. Keep this property
read-only until a rendered before/after capture establishes visual contribution
and a controlled range; the remaining foreground fields and other Variant-14
families still require their own probes.

The Regular/Clear matrix-family gate is closed. A fixed
`Variant 1/2 × Main Off/On × vibrantColorMatrix Slot 1/2` suite passed all
eight cases. Boolean-vector and matrix-coefficient mutations matched model and
presentation values immediately and after settling, never changed the peer
slot, and reconstructed to the system baseline. Every write replaced the
installed CAFilter, with no attached animation key path. The production editor
therefore relocates by full structural slot and atomically re-boxes the matrix
on every restamp.

### P0.5 — Override lifecycle

Override is persistent desired state, not ownership of a private object.

```text
Recipe/context/layout change
        |
        v
AppKit may replace topology or pass instances
        |
        v
Rediscover structural target
   |                     |
found                 absent
   |                     |
restamp              mark Dormant
                         |
              restamp if target returns
```

The implementation must:

- never retain an old layer/filter/effect as the Override identity;
- relocate the target after Variant, Subvariant, Main/Subdued, size, layout, or
  renderer replacement;
- preserve desired values while a target is absent without injecting a pass;
- avoid transferring a property between similarly named but semantically
  different foreground/background passes;
- report ambiguous matches instead of silently selecting the first instance;
- remove or supersede presentation animations that would visually undo a
  successfully restamped model value.

### P0.6 — Targeted geometry replay

Do not immediately multiply the 12 MB recursive fixture into a full 1,008-tree
matrix. Replay Height 24 and 600 for:

- cells whose fixed Height 200 topology or values changed;
- cells the compact Matrix already proves are size-sensitive;
- macOS 26 Height 24 Variants 9, 15, 17, 19, and 20, whose Subvariant
  consumption is compact-only in the current evidence.

Expand the full recursive Cartesian product only if targeted samples establish
additional topology or property families.

### P0 exit criteria

P0 is complete when:

- every pass observed in the accepted Recipe domain is visible in the App;
- writable properties have a measured mutation and reset contract;
- duplicate instances are independently addressable;
- Recipe reconstruction never writes through stale object references;
- an absent pass produces an accurate Dormant Override that resumes when its
  target returns;
- the macOS 26/macOS 27 recursive delta is classified;
- target production topologies are complete enough to begin a coordinated
  Material Strength curve without known silent contributors.

Pass injection is explicitly not a P0 exit requirement.

## P1 — Material Strength and system preset-curve research

### Product question

A production HUD may need a continuous control that reduces the visual strength
of Glass without applying opacity to the already-composited view. Whole-view
opacity simultaneously destroys tint, blur, refraction, edge lighting, and
contrast; the desired control coordinates material contributors before final
composition.

The public model should remain one scalar while the implementation may control
several complete-pass groups:

```text
Material Strength 0...1
          |
          +-- Face / tint / color matrix
          +-- Backdrop blur / refraction / bleed
          +-- Foreground / displacement
          +-- Gradient / shadow / fill
          +-- Key-fill and Glass highlights
          +-- Output reach / layer gates
          `-- Discrete composition policy where required
```

The two common `vibrantColorMatrix` slots are not planned as 20 independent
product controls. P1 first isolates them against diagnostic color content:

1. Hold the complete Recipe fixed and replace only Slot 1 or Slot 2 with an
   identity matrix.
2. Sweep `identity → system matrix` independently for each slot while recording
   rendered deltas, layer gates, model/presentation state, and replacement.
3. Confirm whether Slot 1 is a Content/Vibrancy grade; keep that name
   provisional until the visual isolation is positive.
4. Treat Slot 2 as the Rim post-grade and test it together with Rim amount,
   colors, and opacity rather than assuming it is an independent contributor.
5. Expose a semantic strength scalar only if the interpolation is continuous
   and preserves expected hue, luminance, and alpha behavior.

The curve is perceptual. It is not assumed that every property is linear, that
every channel reaches numeric zero, that all contributors start at the same
time, or that every Variant shares one curve.

P1 can start once the intended production Variant/topology has satisfied P0;
it does not wait for every theoretical private pass on every system surface.
The Regular/Clear target now satisfies that gate: all five observed passes have
accepted controls, while V14/V19 remain explicitly scoped outlier topologies.

### P1.1 — SwiftUI Materialize/Dissolve preset investigation

The public SDK exposes `GlassEffectTransition.materialize`, alongside
`matchedGeometry` and `identity`. It does not expose a public transition named
`dissolve`; this roadmap uses “Dissolve” as the provisional name for the removal
direction of a materialize transition until runtime evidence establishes a
separate mechanism.

The local macOS 26.5 SwiftUICore symbol inventory also exposes internal
`GlassContainer.AppearanceSettings.materialize` and `.match`, with properties
named `scale`, `maxPointScale`, and `blurRadius`, plus `reduceMotion(_:)`.
This is evidence for a coordinated preset endpoint/vector. It is not yet proof
of a role-specific timing curve or of interpolation across Shader/SDF knobs.

#### Initial contract findings — 2026-07-27

The public/SDK inventory phase is complete:

- the same `.materialize` value is the public transition for both insertion and
  removal; there is no public `.dissolve` case;
- Apple documents a content fade plus a Glass-material animation in or out,
  with no geometry matching to another Glass effect;
- Apple describes the material behavior as gradually introducing/removing
  light bending and lensing, not merely fading the completed Glass surface;
- local reflection finds a fixed private `materialize` kind with no reflected
  caller payload; the public API exposes no duration, curve, blur, scale, or
  per-channel controls;
- the existing Semantic surface disables transaction animation, and its
  snapshot captures model layers only. It cannot be used as the transition
  recorder without a dedicated animated path and presentation-layer capture.

These findings establish the API boundary, not the actual interpolation. In
particular, they do not prove that outer transaction progress maps linearly to
material progress, that removal reverses insertion, or that Regular and Clear
share one preset.

#### First runtime findings — 2026-07-27

The dedicated Transition probe is implemented and fixed-context captures are
complete for:

- Main Off Regular and Clear: system-default insertion/removal and four-second
  linear insertion/removal;
- Main On Regular and Clear: four-second linear insertion/removal.

The harness treats the selected Semantic page as Preview ownership rather than
requiring a separate preparation step. Entering Transition mounts a fresh
Presented Materialize surface; automated capture normalizes Panel,
480×200@16, Margin 40, and the selected Main participation, then waits for the
actual non-key Main state before sampling. Manual In/Out remains available in
the current Preview context for qualitative inspection.

The initial evidence changes the working model:

1. Materialize is not an ordinary CAAnimation inventory. No attached
   `CAAnimation` was present; SwiftUI updates model layer/filter values each
   frame.
2. A four-second linear outer transaction produces a scalar `g` that tracks
   normalized transaction progress. Content opacity and
   `glassBackground.inputFaceOpacity` equal `g`.
3. The transition maps `g` across coordinated channels: nonuniform content
   scale, temporary content Gaussian blur, base-background material values,
   and a temporary foreground aberration/refraction pass.
4. The normalized content and temporary-foreground mapping matches between
   Regular and Clear, but the base-background endpoint is role-specific
   (including Regular blur 4 plus bleed versus Clear blur 10 with no bleed).
5. Topology changes during the transition: temporary `gaussianBlur` and
   `glassForeground` filters exist only while materializing. The stable
   endpoint retains `glassBackground` and `vibrantColorMatrix`.
6. Explicit-linear removal drives the same vector from `g = 1` to `0`.
   Against insertion samples indexed by observed `g`, the worst normalized
   continuous-filter residual is approximately `0.11%` for Regular and `0.29%`
   for Clear. Clear `inputBleedDarkenBlend` is a discrete Boolean edge.
7. Existing NSGlass Regular/Clear `glassBackground` passes accept the shared
   vector directly: Regular applies and reads back all 22 changing fields;
   Clear applies and reads back all 23. Stable NSGlass lacks the temporary
   content `gaussianBlur` and `glassForeground` passes.
8. Main On preserves the same pass topology and still attaches no
   `CAAnimation`, but it changes the endpoint rather than merely multiplying
   the Main-Off vector. The changing `glassBackground` surface expands from
   22 to 38 fields for Regular and from 23 to 33 for Clear. The key-fill Rim
   owner gate also changes discretely from opacity 0 to 1 at the first active
   frame and stays open; it is not driven continuously by `g`.

This is direct evidence for a multi-channel material curve with role- and
participation-specific endpoints, discrete context gates, and temporary passes.
Hypothesis 1 is partially accepted for the outer timing-to-`g` relationship;
hypothesis 2 is partially accepted for Regular/Clear's normalized mapping;
hypothesis 3 is confirmed for endpoint vectors and participation gates;
hypothesis 4 is accepted for uninterrupted Regular/Clear transitions in both
measured participation states. Hypothesis 5 has no supporting evidence in
these public roles. Reduced Motion research is intentionally omitted.

#### Tint routing addendum — 2026-07-27

The fixed-context Full Tint Study is complete for public Regular/Clear:
28 AppKit static rows, 20 SwiftUI static rows, and 40 Materialize runs / 360
samples across Main Off/On, nil, Coral 25/50/100%, Cyan 50%, and both
directions.

The result corrects the earlier assumption that Tint must modify one of the two
common untinted matrices:

1. Nonnil Tint inserts its own four-pass
   `CASDFGradientEffect → vibrantColorMatrix → destIn → CASDFFillEffect`
   branch. Nil and nonnil AppKit trees have five and nine passes respectively.
2. The Tint matrix is identical between AppKit `tintColor` and SwiftUI public
   `Glass.tint(_:)` for all 16 comparable nonnil endpoint rows. Regular and
   Clear also share it under the same participation context.
3. At settled endpoints, coefficient 18 equals requested alpha exactly. Main
   Off suppresses Coral/Cyan hue into the same neutral matrix; Main On
   resolves distinct hue coefficients.
4. During explicit-linear Materialize, with
   `g = glassBackground.inputFaceOpacity` and source alpha `a`,
   `tintMatrix[18] = a × g²`. Across 256 tinted samples, maximum residual is
   `9.50e-5` and RMS residual `2.13e-5`; a linear model misses by up to
   `0.24979`.
5. Non-alpha Tint coefficients remain at the static endpoint within
   `7.45e-5`. The Tint `CASDFElementLayer` bounds follow
   `480 + 16(1-g)` by `200 + 16(1-g)` within `8.0e-4` points.
6. SwiftUI still uses model mutation rather than attached `CAAnimation`.
   The Tint model branch follows insertion/removal lifecycle, while the
   presentation branch appears only at settled insertion and preflight
   removal.
7. The proposed AppKit `_tintOpacityReduced` control is unavailable on this
   runtime: neither guarded setter nor getter selector exists. Reduced-attempt
   rows match their baselines because no write occurred, not because an
   accepted flag was proven visually inert.

Static Tint transplantation is therefore closed: set
`NSGlassEffectView.tintColor`. The non-injecting AppKit Materialize probe now
preserves that public Tint branch and applies `a × g²` only to matrix
coefficient 18. Coral-50 readback matched at Regular Main Off `g = 1`, `0.5`,
and approximately `0`, and at the `g = 1` endpoints for Regular Main On plus
Clear Main Off/On. Complete equivalence still requires SwiftUI's branch
lifecycle and changing SDF geometry.

#### Full environment matrix and baseline-driven curve — 2026-07-27

The accepted direct archive supersedes the original 64-run fixed-geometry
matrix. Its dynamic section contains 104 runs / 936 samples on build
`25G5065a`: the full Regular/Clear × Main × appearance × Tint × direction
product at `shortSide` 48/200/400, plus controlled backdrop and repeat slices.
Every run is context-accepted. It resolves the remaining environment questions:

1. Backdrop luminance changes no model-side value at all: 32 compared pairs,
   0 differing channels, maximum difference exactly 0. Backdrop is therefore
   not an input to the curve. This is consistent with backdrop adaptation
   living in the render server's `inputBackdropAware` matrix, which never
   appears in model state. Only two controlled flat colors were sampled;
   real desktop content and HDR extremes remain untested.
2. Appearance does change endpoints: all 32 pairs differ across 20–23
   channels, up to 1.482. The largest deltas are the Content/Rim
   `vibrantColorMatrix` coefficients, which the Recipe resolves differently
   per appearance rather than animating; the transition itself never moves
   them.
3. Normalized channel shapes agree across appearance within 5.1%, and every
   one of the 40 worst channels falls in a single cell with a batch of purely
   linear channels sharing an identical 0.0357 deviation — the signature of a
   two-to-three frame sampling offset in a one-second transaction, not a
   shape difference.
4. Topology is identical across all 16 comparison groups.

At the 200pt reference geometry, endpoint parity with the static AppKit Recipe
is exact across all four Regular/Clear × Main contexts, including
`inputBleedAmount` 70, `inputBlurDistance0` −100, and
`inputBleedBlurRadius` 140.

That reference-size parity is what allows the probe to stop hard-coding most
endpoints. Each channel resolves as
`start + (endpoint − start) × shape(g)`, where the endpoint is captured from
the live Recipe and `start` is the measured 0 or 1. Appearance, Variant, and
participation therefore need no authored endpoint table at the reference
geometry; the compact adaptive exception is handled separately below. Fitting
the original 576 samples leaves only five dimensionless shapes:

```text
linear         g
quadraticFlat  0.2g + 0.8g²          blur opacity 1/2, Main Off
quadratic      0.4g + 0.6g²          blur opacity 1/2 Main On, and 3/4
height         g + 0.08g(1 - g)      the shadow-height family
clamp          (0.34g + 0.036g²) / 0.376   Clear's inputClamp
```

plus context/discrete behavior: participation selects the blur-opacity shape,
Variant selects the `inputClamp` shape, Clear DarkAqua steps
`inputBleedDarkenBlend` at `g = 0.5`, and
`inputSDRHoldingToneEnabled` plus the Rim owner are active-material gates.
The direct archive now verifies all single-endpoint continuous channels within
the accepted bound and names the compact dual-endpoint exception below.

#### Geometry spot check — shapes are not size-invariant

A 12-run sweep (`shortSide` 48/200/400 × Regular/Clear × Main Off/On, Aqua,
Light backdrop, nil Tint, insertion) refutes the expectation that the shapes
are size-invariant. Fitting `value(g) = endpoint · (g + c·g(1-g))` per channel
per size returns a `c` that moves systematically:

| shortSide | fitted `c` | `min(0.2 · S, 16)` |
|---:|---:|---:|
| 48 | 0.200 | 9.6 |
| 200 | 0.080 | 16 |
| 400 | 0.040 | 16 |

The cause is directly observable rather than inferred. Materialize inflates the
`CASDFElementLayer` short side by `min(0.2 · shortSide, 16)` points and retracts
it with the outer transaction, not face-opacity `g`. The direct capture keeps
those two clocks separate and matches the View Envelope model within 0.5pt
across all three sizes. As a fraction of the resting side the inflation is
`min(0.2, 16 / shortSide)`, which is exactly the fitted `c` when the outer
transaction and material clocks align. The previously authored `height`
constant `0.08` was never a universal shape constant — it is `16/200`, this
effect projected onto the baseline geometry.

Most endpoints still need no authored table: they are read, and the sweep
confirms the system resolves the size-scaled families correctly
(`inputBleedAmount` 16.8/70/140 = `0.35 · shortSide`;
`inputShadowHeight` 19.2/80/160 = `0.4 ·`). The compact adaptive face grade is
the exception described below. The sweep also surfaced endpoint behavior that
the previous hard-coded form got wrong outright: `inputBlurRadius` is not a
per-Variant constant but caps out, resolving 2/4/4 for Regular Main Off and
5/10/10 for Clear Main Off.

Making `height` take the inflation ratio drops the worst residual at
`shortSide = 400` from 2.00% to 1.00% and reduces channels above 0.5% from 8 to
1; at 48 the count falls from 12 to 5. The baseline geometry is unchanged at
0.096%.

The residual is a second-order consequence of the same effect: a channel that
is capped tracks the cap instead of the inflating geometry, so it reads as
linear, and which channels are capped depends on size. At `shortSide = 400`
`inputBleedBlurRadius` caps at 160 and goes linear while the rest of its family
stays quadratic; at 48 `inputShadowAmount` and both inner-refraction channels
leave their caps and become quadratic. Resolving this exactly would require
authoring a ratio and cap per channel — the table baseline capture was adopted
to avoid — so it is deliberately left as a bounded error.

The direct cross-section comparison found one separate compact-size exception.
At `shortSide = 48`, the Materialize animation endpoint uses a different
adaptive face grade from the long-lived static Recipe. During removal,
`inputFaceColorMatrixBlack` and `inputFaceColorMatrixWhite` traverse both
grades, so a single read baseline cannot reproduce those two channels. At
200/400 the endpoints agree. Every other channel remains within the documented
bound, and the scalar remains monotonic; exact compact removal requires a
future dual-endpoint face-grade model.

**This is macOS 26 only.** The direct macOS 27 capture resolves one endpoint at
48, 200, and 400pt, so no dual-endpoint model is needed there. macOS 27 does
break monotonicity on one channel, for an unrelated and fully modelled reason:
its size-gated `inputBlurOpacity0` resolves `g · (1 - (1 - endpoint)g)`, which
turns inside `0...1` whenever the endpoint is below 0.5.

Test these distinct hypotheses:

1. Materialize is a fixed appearance endpoint and the surrounding SwiftUI
   transaction supplies an ordinary timing curve.
2. Materialize maps normalized progress through several coordinated appearance
   channels but uses one mapping for all Glass semantic roles.
3. Specific public/private semantic Variants select different endpoint vectors,
   pass gates, channel curves, or topology changes.
4. Removal is the exact reverse of insertion.
5. Dissolve/removal uses a direction-specific sequence or different timing.
6. Reduced Motion selects another preset rather than merely shortening the
   animation. This hypothesis is intentionally out of the current product
   scope.

#### Capture protocol

For a controlled SwiftUI host and fixed Shape, size, backdrop, appearance, and
real window participation:

1. Use a dedicated transition probe. Keep the current static Semantic host's
   animation suppression and snapshot contract unchanged.
2. Insert and remove one Glass child inside `GlassEffectContainer` using
   `.materialize`.
3. Capture the system-default transaction, then repeat with an explicit linear
   transaction to separate transition mapping from outer animation timing.
4. Sample at normalized progress `0`, `0.125`, `0.25`, `0.5`, `0.75`, `0.875`,
   and `1`, with additional samples around any pass pop-in or inflection.
5. Record model and presentation layer trees, pass topology, every resolved
   filter/effect value, layer gates, transforms, blur, attached CAAnimation
   key paths, duration, timing functions, and keyframes.
6. Run insertion and removal independently; do not infer Dissolve by reversing
   Materialize samples.
7. Repeat with interrupted/reversed transitions if lifecycle behavior becomes
   relevant; Reduced Motion is not required for this lane.
8. Start with public Regular and Clear, then representative private roles whose
   resolved topologies differ: Regular, Menu, Camera, Siri, and a simple
   control/text role.
9. Normalize each changing channel and classify it as global, role-specific,
   direction-specific, gated, discrete, or unrelated to material strength.

The output should distinguish an endpoint preset, a timing function, and a
multi-channel material curve. Only the last category is a direct candidate for
reuse; endpoint and timing evidence can still seed an AppKit curve.

The sampled domain is Regular and Clear only, at `shortSide` 48/200/400, with
both participation states, both appearances, controlled backdrop slices, and
insertion/removal captured separately. Explicit-linear direction symmetry is
accepted for the single-endpoint channels, excluding the discrete gates,
endpoint-only Rim spread cleanup, and the compact dual-endpoint face grade.

The single-endpoint numeric side is closed at the 200pt reference geometry and
for every non-adaptive channel in the 48–400 sweep. Exact 48pt removal still
needs the dual-endpoint face-grade model above. The next useful work is visual
isolation across representative backdrops — no acceptance so far rests on
anything but model readback, so the exit criteria covering perceived
monotonicity and zero-endpoint residue are still entirely unevidenced.
Interrupted reversal, non-Panel hosts, and private semantic roles remain
deferred.

#### NSGlass transplant boundary — 2026-07-27

The Recipe `Materialize` page is a non-injecting compatibility probe. It
automatically prepares its selected Main Off/On endpoint in the same
Panel/480×200@16/Margin-40 context on entry and exposes a scrubbable `g` plus
four-second Linear In/Out replay only after actual Main/Key participation
settles. Main-On preparation pauses while the application is inactive and
continues after activation, so inactive AppKit state cannot be mistaken for an
accepted Main-Off endpoint.

| SwiftUI Materialize contributor | NSGlass Regular/Clear status |
|---|---|
| `glassBackground` changing vector | Existing pass; every channel present in the captured baseline is scaled and read back. Main Off resolves 22 Regular / 23 Clear changing fields, Main On 38 / 33; these counts are now an observation about which endpoints differ from their start, not an authored per-context vector |
| Whole-content opacity and X/Y scale | Available as an opt-in comparison envelope; excluded from material-only judgment by default |
| Temporary content `gaussianBlur` | Absent; not injected |
| Temporary `glassForeground` | Absent; not injected |
| Untinted Content/Rim `vibrantColorMatrix` | Present but unchanged by the Tint-nil captured sequence; untouched |
| Tint-owned `vibrantColorMatrix` | Static endpoint parity exact; AppKit replay writes coefficient 18 as `a × g²` with accepted model readback in Regular/Clear Main Off/On |
| SDF Output and Main-Off Rim | Present but unchanged/gated; untouched |
| Rim owner gate | Discrete: 0 at `g = 0`, the captured opacity above |

This proves that the shared background portion can seed an AppKit Material
Strength curve without topology changes. It does not prove complete visual
equivalence to SwiftUI Materialize: the missing temporary blur/foreground
passes account for appearance that cannot be reproduced by background knobs
alone. Pass injection remains P3 rather than being smuggled into P1.

Main Off and Main On no longer need separate authored paths. Participation
selects the blur-opacity shape and opens the Rim gate, while every endpoint
difference between the two — including the fields that only move under Main —
arrives through the captured baseline.

### P1.2 — Required baselines

Compare under identical geometry and content:

1. current whole-backdrop `alphaValue`;
2. proposed AppKit complete-pass Material Strength;
3. public SwiftUI Regular/Clear endpoints;
4. sampled SwiftUI Materialize insertion and Dissolve/removal paths;
5. any role-specific preset curve established by P1.1.

Use the intended production HUD size plus compact and enlarged surfaces.
Exercise static high-contrast text, saturated boundaries, fine patterns, and
moving content behind the Glass. Capture and preserve the source Recipe before
changing any contributor.

#### What the macOS 27 set has to settle — 2026-07-27

The cross-version learnings now state the open question mechanically instead of
in prose. `Golden/learnings/cross-version.mjs` reports:

- **the channel table still resolves.** None of the 42 channels the strength
  curve classifies has disappeared on macOS 27, so the abstraction survives
  structurally. This is a hard assertion and it passes.
- **the channel table is not complete.** macOS 27's `glassBackground` publishes
  77 properties against macOS 26's 55. All 22 additions are unclassified —
  aberration, blur-fill, key-fill highlight, ring shadow, and two face
  color-matrix luma inputs.

A key absent from the table is never written by the controller, so it keeps
whatever the system last left there. Whether that is correct depends entirely on
whether any of the 22 animates during a transition, and **only a dynamic capture
on macOS 27 can answer it**. Until then the learning reports `unverifiable` and
names exactly that. When the capture lands it either confirms all 22 are static
or names the channels to classify — which is the whole reduced set, expressed as
a test rather than a note.

#### Settled by the direct macOS 27 capture — 2026-07-28

The capture landed and **17 of the 22 animate**, so the omission was real: left
untracked, a glass held at `G = 0.3` would have rendered with a full-strength
ring shadow and blur fill. All 17 are now in the table.

The remaining five are not one homogeneous "static" bucket.
`inputKeyFillHighlightAngle` resolves one value across all 832 dynamic samples
and is verified static. The four `inputAberration*` properties never resolve a
numeric value anywhere in the public Regular/Clear dynamic section, so they are
**unresolved in the sampled domain**, not verified static and not inputs the
controller can currently author. That does not leave a live transition value
behind — a missing baseline endpoint is skipped — but it remains an explicit
scope boundary. The cross-version learning reports the split and fails if an
unclassified input ever begins moving.

Classifying the 17 animated additions was cheaper than expected. Every one is
linear in face progress — normalized against its own start, each traces the
`inputFaceOpacity` profile to within 1e-3 across 52 insertion runs — so no new
shape was needed, only new start values, three of which are neither 0 nor 1
(`0.4`, `-0.25`, `1.309`). An earlier reading that `clamp` fit better on mean
error was wrong: the systematic offset it captured is the sampling lag every
channel shares.

macOS 27's one genuine non-linearity is elsewhere, on a channel that already
existed. `inputBlurOpacity0` is gated off below a 64pt short side and ramps to
0.8 by 160pt, and mid-transition it overshoots its gated endpoint by exactly the
amount that endpoint falls short of full opacity:

```text
value(g) = endpoint·g + (1 - endpoint)·g(1 - g)
```

The coefficient on the deficit is 1 — nothing fitted. Worst absolute error
0.00008 over 448 samples, against 0.24980 for a plain linear ramp. The term is
self-cancelling where it should be: Clear resolves an endpoint of 1 on both
systems, as does Regular at every size on macOS 26, so `(1 - endpoint)` is zero
and it reduces to the ramp measured there. One table, both systems, no version
branch and no variant branch.

##### Why the hump exists — 2026-07-28

Reproducing it was briefly questioned on the grounds that a strength control
should be monotonic, and below a 124pt short side this channel is not. That
reasoning was wrong, and the archive says why.

`inputBlurOpacity2` is quadratic, so it starts slower than linear and runs a
deficit of `0.3 · g(1 - g)` early in the ramp — the same basis as the hump.
`inputBlurOpacity0` carries that early load and hands off as the quadratic
catches up. The two taps are a **crossfade**:

```text
48pt Regular, Main on        Opacity0   Opacity2      sum   without the hump
g = 0.23                       0.1759     0.0611   0.2370             0.0612
g = 0.49                       0.2498     0.1681   0.4179             0.1681
g = 0.85                       0.1246     0.3897   0.5143             0.3897
g = 1.00                       0.0000     0.5000   0.5000             0.5000
```

The sum is monotonic in 24 of 28 sampled cells and steps backwards by at most
2.9% of its resting value in the other four — a plateau overshoot near the top
of the ramp, not a fade. Flattening the hump would not buy monotonicity; it
would delete the compensator and leave the slow quadratic alone, so blur would
arrive late and abruptly. At `g = 0.25` the pair reads 0.256 with the hump and
0.069 without.

A single channel being non-monotonic is not the same as the perceived quantity
being non-monotonic. The P1.3 checklist already asks for exactly that
distinction — "verify monotonic perceived strength without assuming monotonic
raw values" — and this is the first case where the two actually come apart.
`the-blur-taps-crossfade-so-perceived-blur-stays-monotonic` asserts it.

One residual is accepted rather than modelled: `inputBlurOpacity1` humps in the
same basis but needs a coefficient per participation whose derivation is not
understood, and at 48pt under Main its endpoint is zero, so the controller emits
a flat zero while the system reaches 0.05. That is the largest remaining
deviation on macOS 27. It carries an explicit ceiling in
`gated-blur-overshoots-by-its-saturation-deficit` — reporting the number without
bounding it would have let a future regression from 0.05 to 0.5 print green.
The ceiling is 5.25%: the ordinary compact 5% replay bound plus the same 5%
numerical slack used by the general channel replay assertion.

### P1.3 — Curve construction

Sample at minimum `0`, `0.125`, `0.25`, `0.5`, `0.75`, and `1`. For every point:

- record all authored values across the complete target topology;
- verify monotonic perceived strength without assuming monotonic raw values;
- check residual tint, blur, refraction, displacement, shadow, gradient, halo,
  or clipped reach at the zero endpoint;
- check pass pop-in, hue shift, darkening, and intermediate discontinuities;
- repeat after Main/focus changes and a resize that forces Recipe resolution;
- isolate contributor groups before fitting a combined curve;
- compare the fitted curve with the observed Materialize/Dissolve channels and
  document every intentional divergence.

#### Visual acceptance — 2026-07-27

The author reviewed the baseline-driven scalar against representative content
and against whole-view `alphaValue`, and accepted both:

- perceived strength is monotonic, with no pass pop-in, hue shift, or
  intermediate discontinuity;
  - this was reviewed on **macOS 26**, where every raw channel is monotonic too.
    macOS 27's size-gated `inputBlurOpacity0` is not, by measurement, so the
    perceived-monotonicity acceptance does not carry over to a small glass on 27
    and needs a fresh review there;
- `g = 0` leaves no residual tint, blur, refraction, shadow, or halo;
- intermediate values stay recognizably Glass rather than reading as a faded
  composite, which is the behavior `alphaValue` cannot produce.

This is an author visual acceptance, not an instrumented measurement. Unlike
every other accepted result in this lane it has no fixture behind it, and it
was performed on macOS 26 only. It should be repeated before any release that
changes the curve, the target OS, or the production surface.

### P1.4 — Runtime and performance

Static cost and animated-transition cost are separate measurements. With the
same surface area, display, backdrop, Recipe, and update rate, record:

- app CPU while the strength value changes;
- WindowServer/render-server and GPU cost where Instruments exposes them;
- layer/pass replacement and retained-layer growth;
- frame pacing of content behind the HUD;
- event-driven restamp cost after setting, Recipe/context, renderer, and
  geometry changes.

Production code must not rewrite material values on every unrelated HUD metric
sample.

### P1 exit criteria

P1 is complete when:

- ✅ the system Materialize/Dissolve behavior is classified as endpoint preset,
  timing curve, multi-channel curve, or a combination — it is a multi-channel
  curve over read endpoints, with three discrete behaviors, a size-dependent
  geometry term, and one documented compact dual-endpoint face-grade exception;
- ✅ role/Variant and direction dependence are known for the sampled domain;
- ✅ strength `1` reproduces the accepted source Recipe — by construction, since
  the endpoints are captured from it. Qualified below 200pt: see "Two endpoints
  below 200pt";
- ⬜ strength `0` has no residue beyond the explicitly chosen endpoint — author
  visual acceptance passed on macOS 26 and the numeric endpoint is verified on
  macOS 27, but the targeted macOS 27 visual acceptance remains;
- ⬜ intermediate points remain continuous and recognizably Glass — author visual
  acceptance passed on macOS 26; the compact macOS 27 path still needs review.
  The numeric evidence now supports it: the one non-monotonic channel there is
  half of a crossfade whose sum is monotonic to within 2.9%, so this is a
  confirmation pass rather than an open question;
- ✅ context/resize reconstruction cannot permanently replace the authored state
  — closed by the controlled resize test below;
- ⬜ runtime cost is measured against whole-view alpha — P1.4 is untouched;
  the visual comparison against `alphaValue` has been accepted, the cost
  comparison has not;
- ✅ a consumer can expose one strength control while low-level pass inputs
  remain implementation detail.

The reduced macOS 27 capture and curve modelling are complete. Two work items
remain before the cross-version P1 claim is closed: targeted visual acceptance
of the compact macOS 27 path, and the P1.4 runtime-cost comparison. No additional
full capture matrix is required for either.

#### Two endpoints below 200pt — 2026-07-28

The first direct Golden capture swept short sides the earlier archive never did,
and 48pt turned out to have **two** "fully materialized" states rather than one:

```text
shortSide 48, Regular, Light      inputFaceColorMatrixBlack
  long-lived glass (static Recipe)              0.4875
  glass that completed a Materialize In         0.8000
shortSide 200 and 400                    both endpoints agree
```

Three channels diverge — `inputFaceColorMatrixBlack`,
`inputFaceColorMatrixWhite`, and `inputClamp` — and only below 200pt. Since a
dissolve traverses both grades, no single read endpoint can replay it, and the
worst channel error reaches 17% at 48pt against the documented `min(5%, 4/S)`.

**Accepted without further work.** The affected channels are the face color
grade, so the visible consequence is a mid-fade tone difference on a very small
glass rather than a pop, a wrong material, or a geometry error. Both endpoints
stay exact, and every other channel stays inside the ordinary bound. The
measured bound in `GlassMaterialStrength` has been corrected to say so.

`Golden/learnings/cross-section.mjs` owns this: it hard-asserts that the two
endpoints agree at the reference geometry — a regression there would be real —
and reports which sizes and channels diverge on every capture, so a future
release moving the threshold shows up without anyone re-deriving it.

**macOS 27 is not affected.** The direct 27 capture resolves one endpoint at 48,
200, and 400pt, so the divergence above is a macOS 26 phenomenon and the reported
line on 27 reads `endpoints agree` at every size. That is why the learning reports
rather than asserts the divergence: the same code that documented it on 26 shows
it gone on 27 without an edit.

Two follow-ups came out of it, both now specified in
[`CAPTURE-SPEC.md`](../Golden/CAPTURE-SPEC.md):

- **Removal lifecycle.** The capture that produced the numbers above started
  each dissolve from a directly-created presented view rather than one that had
  genuinely materialized in, so it records the long-lived case only. That is
  also the case a strength control actually meets, since it reads its baseline
  from whatever tree it is handed — but the other case is real too, and the spec
  now requires each removal to perform a real Materialize In on a fresh hidden
  subtree first. The harness implements that lifecycle and takes the removal
  preflight from the same animation-endpoint-plus-100-ms observation as an
  insertion run; it deliberately does not run the later long-lived Recipe
  stability wait. **Both archives have since been recaptured under that
  lifecycle**, so the committed dynamic sections record real removal starts and
  the divergence figures above describe the current harness. macOS 26 still shows
  the three-channel 48pt divergence; macOS 27 shows none at any captured size.
  A dedicated 48pt regression now compares the
  insertion endpoint, the directly-presented endpoint, and the removal
  preflight for Regular/Clear × Main Off/On. Two consecutive macOS 26.6 runs
  passed all four cells. They also exposed small terminal jitter between
  independent Regular insertions (for example `0.7838` rather than exactly
  `0.8`), while the distance from the directly-presented grade stayed an order
  of magnitude larger; the regression therefore tests endpoint provenance
  rather than brittle string identity.
- **Appearance on the static side.** The first direct capture pinned appearance
  to Light. That was an improvement over the earlier archive's uncontrolled
  `null`, but it made appearance a constant rather than an axis, so "which
  Variants follow appearance" was answered for half the vocabulary. The static
  core now sweeps both controlled appearances, and the tree carries a
  one-row-per-Variant DarkAqua slice to settle whether topology follows it at
  all — a question the dynamic section can only answer for Variants 1 and 2.

#### Resize reconstruction — 2026-07-27

Strength is written **once** and never rewritten; everything after that is the
layout restamp re-reading the baseline. Run with
`--verify-resize-restamp`:

```text
step0 short=200 resized=false faceOpacity=0.5000 shadowHeight=41.600 (want 41.600)
step1 short=400 resized=true  faceOpacity=0.5000 shadowHeight=81.600 (want 81.600)
step2 short= 96 resized=true  faceOpacity=0.5000 shadowHeight=20.800 (want 20.800)
step3 short=200 resized=true  faceOpacity=0.5000 shadowHeight=41.600 (want 41.600)
```

Two things had to hold and both did. `g` stayed at 0.5 through every resize
rather than being snapped back to 1 by the system's own reconstruction. And
`shadowHeight` tracked each new geometry's endpoint exactly — at short side 96
that is `0.4 × 96 × shape(0.5, 96) = 20.8` — which is only possible if the
baseline was genuinely recaptured against the new geometry rather than scaled
from the old one.

## P2 — Recipe-axis closure

Complete only axes that can change topology, property capability, resolved
values, or Override reconstruction:

- rerun the existing candidate Subvariant strings (`popover`, `hud`, `window`,
  `toolbar`, `alert`, case/whitespace controls, and an unknown control) on
  macOS 26; promote a name only when it yields a repeatable signature distinct
  from nil;
- close targeted Height 24/600 cells selected by P0.6;
- determine whether inactive-app transitions write an intermediate Recipe
  before Override restamping; this axis now has a production consumer —
  `GlassMaterialStrength`'s frozen-style mode restamps on every participation
  change and currently bounds any such write to one frame with a trailing
  next-runloop refresh rather than knowing whether one occurs;
- isolate Scrim, adaptive appearance, tint/reduced tint opacity, accessibility,
  contrast, and host-type effects one axis at a time;
- preserve real requested and actual key/main participation in every accepted
  sample;
- name an internal environment discriminator only if doing so unlocks behavior
  that controlled participation cannot provide.

P2 does not multiply every known Boolean into one giant fixture. Each axis must
first prove material relevance in a controlled pair.

## P3 — Pass injection/transplant

Injection means preserving or creating a pass that the current Recipe topology
does not contain. It is categorically different from tuning an existing pass
and is not required for product Override or Material Strength.

Do not begin until P0 establishes:

- stable source and destination structural roles;
- copy/assignment behavior for the target pass;
- required source-sublayer, mask, portal, compositing, and ordering dependencies;
- reliable restoration of the original resolver-owned tree;
- a recoverable failure path for invalid private values.

Experiment from lower to higher risk:

1. duplicate/reassign an existing effect within the same owning layer role;
2. transplant between two Variants that already share surrounding topology;
3. add an omitted sibling while preserving source dependencies;
4. only then test complex foreground/displacement chains.

An injected pass is research-only until it survives Recipe rebuild, layout,
Main/Subdued changes, resize, and repeated insertion/removal without layer
growth, crashes, or stale references.

## P4 — Broader SwiftUI private authoring

The Materialize/Dissolve lane is promoted into P1 because it may directly
inform Material Strength. Other SwiftUI private authoring remains deferred.

### Established foundation

Current evidence provides:

- all 24 runtime-delivered `_Glass.Variant.Role` values;
- guarded macOS 26 and macOS 27 opaque-value ABI profiles;
- 48 fixed-context macOS 27 semantic trees;
- declared input inventory for every present CAFilter;
- observed SDF effect families and layer-opacity changes;
- fixed-context overlap between semantic roles and AppKit base payloads;
- a versioned Golden comparator.

### Authoring-level probes

After exact Swift ABI and copied-value behavior are proven, test in this order:

1. `forceActiveAppearance` and `forceSubdued`;
2. `disableOuterRefraction` and `disableEdgeBleed`;
3. `excludingForeground`, `excludingShadow`, and `excludingPlatter`;
4. `minimumDimension`, tint, `frost`, and `smoothness`;
5. `mix(with:by:)` between callable descriptors;
6. Text and Vibrant Fill factories;
7. interaction, accessibility, optimization, and specialized Siri options.

`frost`, `smoothness`, and `mix(with:by:)` remain possible descriptor-level
strength controls, but must be evaluated against the observed P1 system curve
rather than treated as automatically equivalent.

### Resolved-pass fallback

If authoring controls are insufficient:

1. reuse the guarded recursive schema for each generated pass;
2. establish foreground, displacement, gradient, contour, shadow, highlight,
   and output mutation contracts;
3. decode `inputColorMatrix` as a typed matrix;
4. relocate targets after SwiftUI graph replacement using structural identity;
5. compare complexity and runtime cost with the AppKit P0/P1 solution.

SwiftUI replaces an AppKit production backdrop only if it yields the desired
continuous fade with a small authoring surface, stable reconstruction, and
equal or better measured cost. If it requires recursively restamping a larger
multi-pass graph, it remains a research renderer.

## Evidence and maintenance rules

- Record OS version/build, architecture, display state, app activation,
  requested and actual key/main participation, Host, size, corner radius, and
  margin for every accepted capture.
- Reject automated visual captures made while the display/session is asleep or
  while requested and actual participation differ.
- Change one independent variable per mutation probe.
- Keep nil, absent key, absent pass, explicit zero, unreadable, and unavailable
  symbol as distinct states.
- Keep model values, presentation values, and rendered effect as separate
  evidence layers.
- Preserve raw Golden captures; derived classifications and fitted curves must
  be reproducible from them.
- A symbol name or metadata table proves inventory, not callable ABI, endpoint
  values, visual contribution, safe range, or a stable contract.
- Move accepted findings into the appropriate Reverse Engineering document and
  remove speculative wording from this roadmap.
