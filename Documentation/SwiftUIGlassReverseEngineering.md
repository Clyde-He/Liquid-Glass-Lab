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

Apple's public contract describes `materialize` as fading the child content
while animating the Glass material in or out, without matching its geometry to
another Glass effect. Apple's design-session description is more specific
about the material channel: the Glass should not merely cross-fade; its light
bending/lensing is gradually introduced or removed. These statements describe
two coordinated parts of the same transition rather than two competing
definitions: content opacity may fade while the material pipeline changes.

On the macOS 26.6 runtime with the macOS 26.5 SDK, a Swift reflection probe
reports a 25-byte `GlassEffectTransition` value with a private
`_GlassEffectTransition.Kind` discriminator. `identity`, `materialize`, and
`matchedGeometry` resolve to distinct private kinds. The materialize value has
no reflected configuration payload, while matched geometry carries its
properties and center anchor. This confirms that the public materialize API is
a fixed transition selection rather than a caller-configurable curve or set of
appearance parameters.

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

The current Semantic inspector is intentionally static and cannot supply that
evidence yet. `GlassLabSemanticSurfaceView` clears the SwiftUI transaction's
animation, and `GlassLabSemanticSnapshot` reads only the model layer tree,
resolved filters, and effects. It does not capture presentation layers,
attached `CAAnimation` objects, or a time series. P1 therefore requires a
dedicated transition probe rather than treating the existing static snapshot
as a Materialize capture.

### First controlled Materialize capture — 2026-07-27

The Playground now has a separate Semantic `Transition` page. It leaves the
accepted static inspector unchanged and conditionally inserts/removes one
Glass child inside `GlassEffectContainer` with
`.glassEffectTransition(.materialize)`. A capture records the settled start,
the first post-trigger frame, normalized samples at `0.125`, `0.25`, `0.5`,
`0.75`, `0.875`, and `1`, and one settled endpoint. Each JSON sample contains:

- complete model and presentation snapshots, including filter/effect values;
- structured frame, bounds, position, anchor, opacity, transform, sublayer
  transform, affine transform, mask, and visibility fields;
- recursively attached `CAAnimation` metadata.

The first accepted context is macOS 26.6, macOS 26.5 SDK, Panel, 480×200,
corner radius 16, and margin 40. The Main-Off baseline captures Regular and
Clear with system-default insertion/removal and four-second linear
insertion/removal. A second accepted lane captures both roles with Main On and
four-second linear insertion/removal. Reduce Motion is intentionally out of
scope; interrupted reversal remains open.

No sampled layer or mask exposed an attached `CAAnimation`, even though every
run produced distinct intermediate model and presentation states. SwiftUI
instead updates the model layer/filter payload frame by frame. Therefore a
zero attached-animation duration means “display-link/model mutation path,” not
“no animation,” and the model values are required evidence rather than merely
static endpoints.

The four-second linear run exposes a shared normalized scalar `g`. Allowing for
frame-sampling latency, `g` tracks the outer transaction's linear progress.
The measured 480×200 mapping is:

| Channel | Measured mapping |
|---|---|
| Content owner opacity | `g` |
| Content owner scale X | `1 + (1 - g) / 30` |
| Content owner scale Y | `1 + 0.08 × (1 - g)` |
| Temporary content `gaussianBlur.inputRadius` | `10 × (1 - g)` |
| `glassBackground.inputFaceOpacity` | `g` |
| `glassBackground.inputBlurRadius` | Regular `4g`; Clear `10g` |
| Temporary `glassForeground.inputAberrationAmount` | `-5 × (1 - g)` |
| Temporary `glassForeground.inputAberrationAngle` | approximately `(π / 2) × (1 - g)` |
| Temporary `glassForeground.inputRefractionHeight` | `16 × (1 - g)` |
| Temporary `glassForeground.inputRefractionOffset` | `-3.3 × (1 - g)` |
| Temporary `glassForeground.inputEdgeOpacityEnd` | `1 - g` |

The scale constants are scoped to the captured geometry; they are not yet a
size-independent contract. Other background values are coordinated but
material-specific. At `g = 1`, Regular resolves background blur 4, face black
0.2, face white 0.6, and bleed amount/height 70. Clear resolves background
blur 10, face black 0.05, face white 0.8, and no bleed, while both use inner
refraction amount -60, height 20, shadow amount 75, and shadow height 80.

Materialize also changes topology. The active transition owns four observed
filter families: temporary content `gaussianBlur`, base `glassBackground`,
temporary `glassForeground`, and `vibrantColorMatrix`. At the presented
endpoint the temporary blur and foreground filters disappear, leaving the
material's stable background and matrix pipeline. In this original Tint-nil
lane, the sampled matrix description and Main-Off SDF effect values did not
change. Tint adds a distinct matrix branch with a changing alpha coefficient;
that separately controlled lane is recorded below.

Regular and Clear therefore share the measured content/temporary-foreground
mapping and system-default timing shape, while their base-background endpoint
vectors differ.

The explicit-linear removal captures close the first direction question. Both
roles traverse the same filter-channel curves from `g = 1` back to `0`, with
the same active topology and no attached `CAAnimation`. Comparing removal
against piecewise interpolation of the insertion samples by the observed
`inputFaceOpacity = g` produced worst normalized residuals of approximately
`0.11%` for Regular and `0.29%` for Clear across the 27 continuously changing
numeric filter channels. Clear's `inputBleedDarkenBlend` is the expected
exception: it is a discrete Boolean edge rather than a continuous channel.
Within this fixed public-material context, removal is therefore accepted as
the reverse of insertion; interrupted reversal remains a separate lifecycle
question rather than evidence for another removal curve.

### Main-On Materialize capture

The Transition page now selects requested `Main Off` or `Main On` independently
of the material. Starting a capture automatically establishes the fixed Panel,
480×200@16, Margin-40 target, then waits until requested and actual Main match
and actual Key remains false before sampling. Manual Materialize In/Out remains
in the current Preview context. All four Main-On linear runs met the capture
contract.

Main participation does not change the transition topology: active samples
still contain 18 layers and the same `gaussianBlur`, `glassBackground`,
`glassForeground`, and `vibrantColorMatrix` filter families; settled presented
samples contain 15 layers. No attached `CAAnimation` appears. It does change
the endpoint vector and the number of background fields participating in the
curve:

| Role | Main Off changing `glassBackground` fields | Main On | Newly changing on Main On |
|---|---:|---:|---|
| Regular | 22 | 38 | 16 |
| Clear | 23 | 33 | 10 |

Regular's newly active group includes bleed blur/opacity, blur-band distances,
outer refraction amount/height, refraction opacity, SDR gradient/holding-tone
values, and the visible shadow blur/opacity/radius/vibrancy group. Clear adds
blur-band distances, `inputClamp`, face saturation, outer refraction, and the
SDR gradient/holding-tone group.

The stable endpoint itself is context-specific. Representative changes are:

| Channel | Main Off | Main On |
|---|---:|---:|
| Regular bleed blur / opacity | `0 / 0` | `140 / 0.8` |
| Regular outer refraction amount / height | `0 / 0` | `40 / 25` |
| Regular shadow opacity / radius / blur | `0 / 0 / 0` | `0.25 / 24 / 40` |
| Clear blur radius | `10` | `1` |
| Clear face black / white / saturation | `0.05 / 0.8 / 1` | `0.075 / 1.15 / 1.06` |
| Clear outer refraction amount / height | `0 / 0` | `40 / 25` |

The Main-On insertion/removal background curves remain reversible. Comparing
removal with insertion indexed by observed `g` keeps continuously changing
background residuals within approximately 1%; the same discrete Clear
darken-blend exception remains.

Rim behavior is not another continuous `g` channel. The
`CASDFKeyFillHighlightEffect` owner is gated at opacity `0` throughout Main Off
and opacity `1` from the first active transition frame throughout Main On.
Key/fill spread stays around `2.793` during the transition and resolves to
about `2.748` at the presented endpoint. The Rim-owned
`vibrantColorMatrix` shares that owner gate while its matrix payload remains
unchanged. This statement refers to the existing Rim matrix, not the
Tint-specific branch below. Main participation therefore contributes a
context gate plus a role-specific background endpoint, not merely a multiplier
applied to the Main-Off vector.

### Controlled Tint routing and Materialize capture

The Full Tint Study closes the ambiguity between the two matrix slots already
visible in untinted Regular/Clear and the public `Glass.tint(_:)` modifier. Its
fixed contract is macOS 26.6 build `25G5065a`, Panel, 480×200@16, Margin 40,
Adaptive Appearance 2, no Subvariant/Subdued/Scrim/Override, and actual Key
false. It records:

- 28 static AppKit rows: Regular/Clear × Main Off/On × nil, Coral 25/50/100%,
  Cyan 50%, nil Reduced, and Coral-50 Reduced;
- 20 static SwiftUI rows: Regular/Clear × Main Off/On × the five non-Reduced
  tint cases;
- 40 explicit-linear Materialize runs and 360 samples: Regular/Clear × Main
  Off/On × five tint cases × insertion/removal.

Tint does not write either untinted matrix slot. A nil-tint AppKit tree has 16
layers and five passes. A nonnil tint has 23 layers and nine passes because the
material root inserts a separate four-pass branch:

1. `CASDFGradientEffect`;
2. a Tint-owned `vibrantColorMatrix` on the same `CASDFLayer`;
3. a `destIn` compositing mask;
4. `CASDFFillEffect`.

This branch shifts later structural indices but leaves the original
`glassBackground`, Content/Vibrancy matrix, and Rim matrix payloads separate.
Looking only at `glassBackground` or either pre-existing matrix can therefore
never reveal Tint routing.

The Tint matrix is a 4×5 transform. Coefficient 19 in one-based notation
(`matrix[18]` in the exported zero-based array) is the requested tint alpha
exactly at a settled endpoint. The remaining coefficients encode the
environment-resolved RGB transform. Representative matrices are:

```text
Main Off, Coral or Cyan:
[ 0.763780  0.214508  0.021712  0  0.100000 ]
[ 0.063790  0.914558  0.021652  0  0.100000 ]
[ 0.063744  0.214596  0.721660  0  0.100000 ]
[ 0         0         0         a  0        ]

Main On, Coral:
[-0.002289 -0.007702 -0.000777  0  0.921615 ]
[ 0.041266  0.138822  0.014014  0  0.150885 ]
[ 0.029494  0.099221  0.010016  0  0.359190 ]
[ 0         0         0         a  0        ]

Main On, Cyan:
[ 0.041607  0.139967  0.014130  0  0.090644 ]
[ 0.008201  0.027590  0.002785  0  0.714214 ]
[-0.004047 -0.013615 -0.001374  0  0.942856 ]
[ 0         0         0         a  0        ]
```

Main Off suppresses the Coral/Cyan hue distinction into the same neutral
matrix while retaining alpha. Main On resolves distinct hue coefficients.
Regular and Clear use the same Tint branch and matrix in the same
participation context. Across all 16 comparable nonnil static rows, AppKit
`NSGlassEffectView.tintColor` and SwiftUI public `Glass.tint(_:)` produced
coefficient-for-coefficient identical matrices; maximum error was zero.
AppKit also read `tintColor` back with zero component error.

The old `Reduced Tint Opacity` hypothesis is rejected as an AppKit capability
on this runtime, not accepted as an inert visual flag. The guarded private
selector `set_tintOpacityReduced:` and its getter are both absent. All eight
Reduced-attempt rows therefore match their baselines exactly because the write
was skipped. The Playground now disables that control when the setter is
unavailable and exports setter/getter availability so a future runtime can be
tested without mistaking a no-op for a material result.

Tinted Materialize still exposes no attached `CAAnimation`. SwiftUI mutates
the model tree frame by frame. Let:

```text
g = glassBackground.inputFaceOpacity
a = requested source tint alpha
```

Across all 256 samples with a nonnil Tint branch:

```text
tintMatrix[18] = a × g²
```

The maximum residual was `9.50e-5`, RMS residual `2.13e-5`; the competing
linear `a × g` model missed by as much as `0.24979`. Every other Tint-matrix
coefficient stayed at its static endpoint value within `7.45e-5`. The
Tint-owned `CASDFElementLayer` also changes bounds:

```text
width  = 480 + 16 × (1 - g)
height = 200 + 16 × (1 - g)
```

The maximum measured bounds residual was `8.0e-4` points. Its origin also
moves toward the endpoint, but that position mapping remains scoped to the
SwiftUI composition and was not promoted as an AppKit formula.

Model topology inserts the nonnil Tint branch at the first active insertion
frame and retains it through the insertion endpoint; removal retains it
through the active endpoint and drops it only after settling. The presentation
tree exposed it only at settled insertion and preflight removal: 32 of 360
samples. Nil Tint never creates the branch.

The transplant boundary is now precise:

- settled endpoint: use `NSGlassEffectView.tintColor`; static AppKit/SwiftUI
  parity is exact under the measured context;
- portable Materialize channel: after public Tint creates the AppKit branch,
  coefficient 18 accepts `a × g²` with guarded model readback;
- incomplete equivalence: SwiftUI also owns branch lifecycle and changing SDF
  geometry, so alpha mutation alone is not the complete Materialize effect.

The non-injecting AppKit Materialize probe now preserves/edits public Tint,
locates the Tint matrix by its shared owner path with
`CASDFGradientEffect`, and writes no other matrix coefficient. Coral-50 read
back exactly at Regular Main Off `g = 1`, `0.5`, and approximately `0`
(`0.5`, `0.125`, and `9.63e-33` respectively). Regular Main On and Clear Main
Off/On also accepted their `g = 1` value `0.5`, while retaining the previously
accepted background/Rim readbacks. This validates the portable scalar channel,
not SwiftUI's topology or SDF-geometry envelope.

### First NSGlass background transplant

The corresponding AppKit `Materialize` page tests reuse without pretending
that the two renderers own identical trees. Stable Regular/Clear
`NSGlassEffectView` topologies already contain the same `glassBackground`
endpoint payload observed in SwiftUI. The probe applies only changing fields
on that existing pass and reads the resulting model values back immediately:

| Participation / endpoint | Existing changing fields | Result |
|---|---:|---|
| Main Off / Variant 1 Regular | 22 | `22/22` applied and read back |
| Main Off / Variant 2 Clear | 23 | `23/23` applied and read back |
| Main On / Variant 1 Regular | 38 + Rim gate | `38/38` + `1/1` applied and read back |
| Main On / Variant 2 Clear | 33 + Rim gate | `33/33` + `1/1` applied and read back |

The shared pass probe can be scrubbed with `g` or replayed linearly over four
seconds. Most inputs use their measured analytic mapping. The shared
`shadowHeight` curve resolves to `80g + 6.4g(1-g)`; Regular bleed and the
Main-On blur-distance/outer-refraction group are fixed multiples of that
curve. Clear's Boolean darken-blend uses its measured discrete edge at
`g = 0.5`. An optional comparison envelope applies the observed whole-view
opacity and nonuniform scale, but it defaults Off so the background material
can be judged without final compositing opacity.

This establishes a precise reuse boundary:

- `glassBackground`: directly reusable on the existing NSGlass pass;
- whole-view opacity/scale: technically reusable but not a material-only
  strength control;
- content `gaussianBlur`: absent from stable NSGlass Regular/Clear;
- temporary `glassForeground`: absent from stable NSGlass Regular/Clear;
- untinted Content/Rim `vibrantColorMatrix` and SDF Output: deliberately
  untouched because the original Tint-nil SwiftUI sequence did not change
  them; the distinct Tint branch is covered by the controlled study above;
- Tint-owned `vibrantColorMatrix`: coefficient 18 receives `a × g²` and is
  accepted with model readback for Regular/Clear in Main Off/On;
- Rim: Main Off remains system-gated and untouched; Main On writes only the
  observed discrete owner gate (`0` at `g = 0`, `1` for every `g > 0`).

The readback result proves mutation compatibility, not visual equivalence to
the complete SwiftUI transition. Matching the missing temporary passes would
require pass injection or a different composition and remains outside this
non-injecting P1 probe. Main-On is a separate transplant path rather than an
unlock on the Main-Off baseline. Real-window endpoint and four-second Linear
Out checks accepted `38/38 + 1/1` for Regular and `33/33 + 1/1` for Clear at
both `g = 1` and `g = 0`.

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
