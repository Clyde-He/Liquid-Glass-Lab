# Glass Lab Playground

This document describes how Liquid Glass Lab exposes, updates, and
diagnoses the AppKit Recipe and SwiftUI Semantic Glass renderers. It is an
implementation guide for the lab, not the source of truth for Glass behavior.

For measured AppKit recipes, resolver behavior, formulas, and probes, see
[AppKit Glass Reverse Engineering](./AppKitGlassReverseEngineering.md).
For SwiftUI roles, generated pass graphs, AppKit-base overlap, Main behavior,
and customization candidates, see
[SwiftUI Glass Reverse Engineering](./SwiftUIGlassReverseEngineering.md).
For prioritized unknowns and future experiments across both renderers, see
[Glass Research Roadmap](./GlassResearchRoadmap.md).

## Code map

| File | Responsibility |
|---|---|
| [GlassLabState.swift](../LiquidGlassLab/GlassLab/GlassLabState.swift) | Observable renderer, Recipe/Usage, geometry, participation, and Override state |
| [GlassLabSurfaces.swift](../LiquidGlassLab/GlassLab/GlassLabSurfaces.swift) | AppKit Recipe and SwiftUI Semantic hosts, key/main transitions, lifecycle reconciliation |
| [GlassLabTuning.swift](../LiquidGlassLab/GlassLab/GlassLabTuning.swift) | Guarded private access, capture/write paths, knob metadata and grouping |
| [GlassLabSemantic.swift](../LiquidGlassLab/GlassLab/GlassLabSemantic.swift) | Runtime-gated SwiftUI `_Glass` Usage construction and read-only CA layer inspector |
| [GlassLabView.swift](../LiquidGlassLab/GlassLab/GlassLabView.swift) | Renderer/page controls, Inspectors, refresh scheduling, diagnostics and export |

## Two renderer spaces

The lab keeps one entry point and one controlled test window, but it never
mixes the two private identifier spaces:

| Renderer | Source | Selector | Output |
|---|---|---|---|
| Recipe (NSGlass) | `NSGlassEffectView` | AppKit raw `_variant` `0...20` plus `_subvariant` | An AppKit-owned glass view with a Recipe-resolved Shader/Rim tree |
| Semantic Usage (SwiftUI) | private SwiftUI `_Glass` | `_Glass.Variant.Role` runtime tag `0...23` | A SwiftUI-owned composite CA tree that may contain background, displacement, foreground, SDF, gradient, or specialized layers |

The Semantic tags are not values that can be passed to
`NSGlassEffectView._variant`. They are also not the same ordinal table as
`DesignLibrary.GlassMaterialProvider.Variant`, despite both current enums
having 24 cases. The Usage Picker therefore shows a name and its SwiftUI
runtime tag, and performs a `dlsym` availability check for every private role.
An absent role remains visible as Unavailable instead of becoming a fallback
Recipe or an unresolved launch-time symbol.

The private `_Glass` and public `Glass` value layouts are both 40 bytes on the
measured macOS 27 runtime. On macOS 26.6 Build 25G5065a they are both 41 bytes
with a 48-byte stride. The lab allowlists these per-major-version profiles and
also requires the public/private size, stride, and value-witness flags to match
before calling a dynamically discovered getter through an ABI-compatible
`@convention(thin)` function value. There is no direct private symbol
reference, so the 21 Semantic roles missing from the measured macOS 26 runtime
remain individually Unavailable.

## One independently hosted test surface

The lab intentionally has one test surface rather than an in-window Canvas plus
a companion. The control window's Navigation sidebar chooses the `NSGlass` or
`SwiftUI` renderer, and `Host Type` rebuilds that surface as:

- `Panel`: transparent, floating, borderless, and non-activating;
- `Window`: a normal titled `NSWindow` with the former colorful Canvas
  backdrop.

Size, selected Recipe/Usage, Overrides, and requested participation survive a
Host change. Changing Renderer replaces the hosted surface because SwiftUI's
semantic path does not instantiate `NSGlassEffectView`.
Runtime probes ruled out class, style mask, opacity, native shadow, and level as
direct Recipe selectors. Host Type remains useful for backdrop, clipping, and
real AppKit behavior, but it is not treated as a material axis.

The test glass always renders at its requested size. `Window Margin` adds room
inside the host backing surface for refraction, shadow, ring shadow, and SDF
reach that would otherwise clip at the window boundary.

## State axes

The Playground keeps these axes independent:

| Axis | Current values | Meaning |
|---|---|---|
| Renderer | Recipe / Semantic Usage | AppKit raw Recipe pipeline versus SwiftUI semantic composition |
| Host | Panel / Window | AppKit container and visual backdrop |
| Participation | Main Off / On | Neither-key-nor-main versus main-only request |
| Variant | `0...20` | Integer material family |
| Subvariant | nil / menu / sheet / camera | Independent named family selector |
| Subdued | Off / On | Lower-emphasis axis that can suppress the active Shader/Rim payload |
| Scrim | Off / On | Legibility scrim state |
| Appearance | 0 / 1 / 2 | Pinned or adaptive appearance |
| Tint | optional color | Public tint contribution |
| Geometry | width / height / corner radius | Recipe size input and SDF/path shape |
| Overrides | Shader / Rim / geometry payloads | Manual values layered over the resolved Recipe |
| Semantic Usage | SwiftUI role tag `0...23` | Named private role, independently runtime-gated |

Changing one axis must not silently rewrite another. In particular, Host Type
does not reset Recipe or Overrides, and Main Window is not inferred from focus
callbacks.

## Main Window is desired state

`Main Window` is a two-state request with independently reported actual facts:

| Toggle | Accepted state | Baseline payload |
|---|---|---|
| Off | actual key = false, actual main = false | Flat |
| On | actual key = false, actual main = true | Active unless Subdued suppresses it |

There is no separate user-facing `Neither` value. Off requests the
neither-key-nor-main condition. Diagnostics and export accept a sample only
after actual AppKit identity matches the request.

### Host-specific transition mechanics

A Panel permanently refuses key status. Main On temporarily enables
`canBecomeMain`, orders it on screen, and calls `makeMain()` while the Playground
control window stays key.

A titled Window cannot reliably enter main-only directly. The controller
replays the transition established by the signed probe:

1. briefly make the test Window key and main;
2. return key to the Playground control window;
3. call `makeMain()` on the test Window again.

The accepted final state is main-only for both Hosts. Main Off disables the
test host's key/main capabilities and restores control-window ownership.

### Application activation

When the application becomes inactive, AppKit clears the test surface's actual
key/main participation. The Main Toggle remains the desired value instead of
flipping Off. On `NSApplication.didBecomeActive`, the controller reconciles the
request and restores main-only if needed.

This distinction prevents the old failure where the control showed a neutral
state after focus moved even though the test surface still displayed an active
context, or vice versa.

## Update and refresh model

Recipe mutation and readout refresh are separate operations.

### Structural triggers

Variant, Subvariant, Host Type, and test-window visibility are structural. Their
change path must:

1. call `testWindow.sync(with:)`;
2. run `applyRecipe` on the live `NSGlassEffectView`;
3. refresh filter metadata if the pass or input inventory changed;
4. publish settled current values.

An earlier implementation put Variant/Subvariant only in the Inspector-schema
trigger. The Picker changed, but the private Recipe stayed stale until an
unrelated Size, Main, or Host change caused a sync. After separating structural
and lightweight triggers, Panel + Main Off changed directly from Variant 0 to
Variant 2 without switching Host: `inputBlurRadius` moved 5 → 10 and the first
two blur opacities moved 0.8 → 1; returning to Variant 0 restored them.

### Lightweight triggers and settling

Geometry, Main, Subdued, Scrim, appearance, tint, and margin also sync the host
but do not automatically invalidate the cached input schema. Override value
edits are lighter still: they change only the captured payload, never the
window context, so their trigger restamps the live glass directly instead of
running `sync`. Routing them through the full sync replayed window ordering and
deferred context re-resolutions on every slider tick, which made Inspector
drags stall. For the same reason, `sync` skips the Main ordering dance when the
window's allowed and actual participation already satisfy the request, and the
deferred `resolve → layout → restamp` passes coalesce into one cancellable
settle task rather than queueing per event.

An Inspector slider drag is lighter than any trigger: each tick stamps only the
dragged key onto the live tree and invalidates only its own row, because the
value lives in row-local state during the gesture. Committing every tick to the
observable override dictionaries re-evaluates the entire Form (60+ bridged
controls) and rewrites the full ~70-key payload — each key re-fetching the
77-entry input inventory — per tick, which is the drag-stall failure mode. The
dictionaries receive one commit when the gesture ends; that commit runs the
normal Override trigger (full restamp plus debounced settled readout), so the
captured payload, captions, and value fields reconcile after release.
Recipe resolution is asynchronous across AppKit and WindowServer. Every
explicit window-context resolution now runs as one ordered operation:
`resolve → layout → restamp Overrides`. The managed `NSGlassEffectView` also
restamps at the end of each internal layout pass, covering a replacement
CAFilter/SDF tree installed after a Variant, Subvariant, Main, Size, or
activation change. Current-value capture still samples after a short debounce
and two settling intervals, and those samples retain a final restamp as a
safety net rather than serving as the primary lock.

Actual main-window ownership cannot survive application deactivation. The Main
Toggle remains the requested state, while an enabled Override transplants its
captured payload back onto the truthfully inactive/non-main layer tree. Thus
actual main can report `false` without intentionally changing the locked
material to the Flat visual payload.

There is no polling timer. Metadata is cached until a structural change, and an
unchanged `LiveReadoutSnapshot` does not invalidate the large SwiftUI Form.
Matrix capture suspends observation-driven Recipe stamping so the exporter can
walk private axes deterministically.

## Inspector and knob organization

The control window first selects `NSGlass` or `SwiftUI` in Navigation, then
presents renderer-specific page controls so only the current task's controls
are mounted:

- Recipe: `General`, `Glass Filter`, `Rim Highlight`, and `Pass Inventory`;
- Semantic Usage: `General` and `Layer Inspector`.

Recipe General contains geometry, Recipe selectors, test-window context, and
matrix export. The Filter/Rim pages retain their independent Overrides and Knob
groups. Pass Inventory reuses the Recursive exporter traversal to show every
live filter, background filter, compositing filter, object-backed effect, and
mask-owned layer tree without assuming a first Shader or Rim instance.
Semantic General contains the named Usage, its runtime tag and availability,
shared geometry, and the same controlled window context. Its Layer Inspector
flattens the live SwiftUI/Core Animation composition and shows layer paths,
CAFilter inputs, and object-backed SDF effect values.

Pass Inventory is sampled only while its page is mounted so normal Slider and
Override refreshes do not repeatedly read the complete property surface. Passes
are grouped by channel/family, ordered by structural locator, and numbered when
a family has multiple instances. Each pass exposes owner class, object class,
location, raw locator, and a disclosure of declared properties. Property state
(`value`, `nil`, or `unreadable`) is shown separately from its stable value and
Core Animation metadata.

The live state label is `Present` or `Overridden`; an enabled Glass Filter/Rim
Override whose target is absent is reported as `Dormant`. `Replaced` is latched
when a known structural pass slot receives a different reference-backed live
object. The tracker stores only non-owning process-local `ObjectIdentifier`
tokens: it does not retain stale CAFilter/effect instances or add pointer data
to deterministic JSON/signatures. Sampling pauses off the Pass Inventory page,
so Recipe controls remain cheap, while the tokens survive those edits and are
compared when the page returns. Changing Renderer resets the tracker. The page
retains the raw Layer tree and can copy a deterministic full pass/property
report including the current state of each pass.

Pass Inventory also exposes the P0.3 editor contract without assuming every
declared value is a numeric Knob. Each pass is classified as CAFilter Inputs,
SDF Effect Copy/Reassign, Compositing Mode, or unknown/read-only. Property
metadata selects a distinct Numeric, Percentage, Angle, Boolean, Color, Point,
Size, Color Matrix, String, source/image dependency, or typed-array
presentation. Dependencies, matrices/arrays, and discrete compositing modes
remain explicitly read-only.

An `Accepted` label means the same mutation path is already exercised by the
existing editor: `glassBackground` opens Glass Filter, key-fill highlight opens
Rim Highlight, and Output minimum/maximum open Render Bounds. All newly
observed foreground, Glass Highlight, Gradient, Shadow, displacement, and
compositing families stay read-only until their controlled mutation audit is
accepted. The accepted-contract count therefore describes properties with a
known write/reset lifecycle; it is not a count of generic sliders on the page.

Semantic values are deliberately read-only in this first pass. A CA input only
becomes a Knob after its owning Usage/pass, accepted value type, mutation
lifetime, and safe range have been measured. Existing Recipe Knobs are not
blindly applied to similarly named filters in the composite pipeline.

Current values remain readable while Overrides are disabled. The Override
Toggles control editability, not visibility:

- `Override Glass Filter` captures the current numeric, color, point, nil, and
  layer-geometry state, then unlocks those controls;
- `Override Rim Highlight` captures and unlocks the separate SDF rim pass;
- locked controls continue to show the current system Recipe.

The Inspector stores capability separately from value so missing states are not
collapsed into one label:

- a resolved value is shown directly, without `Live` or `Present` prefixes;
- `nil` means the current pass declares the input but the Recipe assigns no
  value;
- `Absent` means the current pass does not expose that input;
- `Pass Absent` means the complete Glass Filter or Rim pass is missing;
- `—` is used only when the test host itself cannot be sampled.

Shader inputs are grouped by rendering role rather than placed in one large
Shader disclosure. Whole groups use broad matrix-response tiers while their
internal authored/alphabetical order remains stable:

- high response: Backdrop Blur, Face;
- medium response: Refraction, Filter Highlight, Bleed, Shadow, Ring Shadow;
- lower-frequency or specialist: SDR/HDR, Blur Fill, Other, Aberration.

The matrix response never reorders individual paired controls inside a group.
All Knobs stay in that stable group order; low-signal fields are not extracted
into a trailing disclosure. A compact `Constant` tag beside the range caption
marks present values that did not vary in the Matrix. Runtime `nil`, `Absent`,
and `Pass Absent` conditions remain visible only in the existing value readout.
This keeps paired controls adjacent without duplicating availability status.

Every Inspector row uses the structure of the Form sections above it: each
Knob is its own Form row with the name on the leading side, a compact
`min ～ max` caption underneath it, and the control plus the current-value
field at the trailing end. Sliders share one fixed width so the control and
value columns align across all sections. Range provenance is hover-only:
the row's help shows the private input key, the effective range, and whether
its bounds came from Core Animation metadata, the measured Recipe Matrix,
semantic angle bounds, or the Playground authoring fallback. A Slider whose
input is currently `nil` renders dimmed at its fallback position instead of
implying a resolved value.

The trailing value field is the row's authoritative number. While that row's
Override family is enabled it accepts exact entry: committed text sets the
override, and clearing the field removes that key's override so the row
follows the live value again. Typed rows (colors, points) surface their
current value in the caption instead, tinted when overridden.

Typed inputs keep typed UI and storage:

- Boolean metadata → Toggle;
- `CGColor` → ColorPicker;
- point values → independent numeric fields;
- source-layer strings → read-only diagnostics;
- numeric values → slider plus exact value readout.

## Override lifecycle

Enabling an Override is the capture operation: the Playground snapshots the
current supported values and explicit nil states, then immediately applies that
payload as the editable lock. Variant, Subvariant, Main, Size, and application
activation changes may continue resolving underneath it; ordered context
resolution and the managed glass's post-layout hook restamp the supported
captured fields onto each replacement.
Private passes or fields that disappear from a newly selected Recipe cannot be
manufactured by the editor and degrade to `Pass Absent` / `Absent`.
The value readout always comes back from the actual runtime object rather than
the saved Override dictionary, so a failed write cannot masquerade as success.

Disabling an Override discards its snapshot, rebuilds the glass, and restores
the current system Recipe. Enabling it again captures fresh current values, not
an older Override. Reset restores edits to the baseline captured when that
Override was most recently enabled.

Stopping writes is not enough to restore a mutated private filter tree: same-
Recipe setter bounces can preserve installed values. Therefore disabling either
Override family replaces only the `NSGlassEffectView`, keeps the host window and
its real participation, reapplies the selected Recipe, and then reapplies any
other Override family that remains enabled. Reset keeps Override enabled and
restamps the captured baseline instead.

`Reset Filter Overrides` restores numeric Shader, typed Shader, nil, and
layer-geometry values to the captured baseline. `Reset Rim Overrides` does the
same for Rim values, colors, and nil states. The underlying private mutation
contracts are documented in the Runtime document's “Private mutation
contracts” section.

## Diagnostics

### Copy Glass Report

Copies the selected Host's layer tree and resolved payload together with:

- requested Main value;
- actual and reported key/main state;
- application activation;
- appearance, Variant, Subvariant, frames, filters, Rim, and geometry.

### Semantic Layer Inspector and Usage Tree export

The Semantic Inspector captures the SwiftUI-owned CA layer tree rather than an
`NSGlassEffectView`. Each CAFilter is first asked for its own `inputKeys`; only
those declared keys are read through dynamic KVC. CAFilter input names usually
do not have Objective-C selectors, so `responds(to:)` is not a valid capability
test for them and previously made every real input value display as nil.

`Copy Semantic Report` copies the currently selected Usage. `Export All Usage
Trees (JSON)` walks all 24 SwiftUI role tags across requested Main Off/On at
the current Geometry, Host, and Window Margin, producing 48 rows. Every row
records:

- role tag, Usage name, and runtime availability/status;
- requested Main plus actual key/main state;
- the flattened layer tree;
- `filters` and `backgroundFilters` with declared inputs and values;
- object-backed SDF effect classes, layer opacity, and readable effect inputs.

Color inputs use a stable `CGColor(model:components:)` representation instead
of `CGColor.description`, which embeds process-local object addresses and would
otherwise produce false Golden diffs between identical captures.

Missing private symbols remain explicit unavailable rows with no snapshot. The
exporter waits for the same 180 ms SwiftUI render settle used by the original
direct probe, prevents idle display sleep, pauses/retries if the application
becomes inactive, writes atomically, and restores the user's original Usage and
Main/window visibility. Format version 2 declares the requested Main and role
tag axes at the document level while retaining `requestedMain` on every entry,
so Off/On trees can be compared without joining separate exports. This is a
structural inventory named
`semantic-usage-trees.json`; it is intentionally separate from the Cartesian
AppKit Recipe Matrix and does not multiply the Size or Host axes.

The accepted macOS 27 fixture lives beside the Recipe baseline under
`Golden/macOS-27`. The shared comparator identifies Semantic rows by
their fixed environment plus `roleTag × requestedMain`, and expands nested
arrays into individual layer/filter/effect fields for actionable OS diffs.

### Export Recipe Matrix

The exporter walks the selected Host through:

```text
3 representative Heights × 2 Main states × 2 Subdued states
× 21 Variants × 4 Subvariant states = 1,008 entries
```

It does not append a second Host reference. Every row contains requested Main
and Subdued axes, actual application/key/main acceptance facts, Shader/Rim pass
flags, and capability key lists. A key listed without a value is nil; a key
missing from the list is absent. A rejected or interrupted transition is
retried; an incomplete product is never written as a valid matrix.

The three canonical size samples use Width 480, Corner Radius 16, and Heights
24/200/600: small, normal, and oversize/capped representatives. Dense size
formula and breakpoint analysis remains the responsibility of the separate
Formula Audit rather than multiplying every canonical Recipe axis. The JSON
uses a versioned document envelope. Its environment records Host and Window
Margin as provenance without sweeping controls already ruled out as direct
Recipe selectors. Capture fixes Scrim and Reduced Tint Opacity Off, Adaptive
Appearance at 2, and Tint at nil. Both Overrides must be disabled so
transplanted values cannot contaminate the system baseline.

The exporter asks for the destination before capture, prevents idle display
and system sleep while running, and pauses whenever the application becomes
inactive. After activation it re-establishes real Main participation and
restarts the interrupted 84-cell context rather than retaining a partial
batch. Recipe settling is adaptive: two identical payload snapshots after at
least 60 ms complete a cell, while unstable cells keep the former 180 ms
safety ceiling. Before writing, the exporter proves all 1,008 Cartesian-product
identities are present, every row was captured active, and actual Main matches
requested Main. Failure or cancellation leaves the destination untouched. The
user's original values are restored when capture ends.

### Export Recursive Pass Audit

`Export Recursive Pass Audit (JSON)` is the structural complement to the
compact Recipe Matrix. It requires the Panel host and fixes Width 480, Height
200, Corner Radius 16, Window Margin 40, Scrim/Reduced Tint Opacity Off,
Adaptive Appearance 2, Tint nil, and both Overrides disabled. It captures:

```text
2 Main states × 2 Subdued states × 21 Variants × 4 Subvariant states
= 336 entries
```

For every cell, the audit traverses ordinary sublayers plus mask-owned layer
trees. Stable paths key layer and pass dictionaries so an inserted pass appears
as one added structural record instead of shifting every later array index. It
records direct `filters`, `backgroundFilters`, `compositingFilter`, and any
object-backed `effect`. CAFilter `inputKeys` and effect `CA_attributes` are
captured as capabilities; every property is independently marked `value`,
`nil`, or `unreadable`, with metadata and stable color/value descriptions.

Each snapshot carries SHA-256 topology and resolved-value signatures. The
topology signature covers layer/pass placement and property-key inventory; the
value signature covers the complete normalized payload. Capture uses the same
adaptive settling, active-session retry, real Main acceptance, atomic write,
and state restoration contracts as the Recipe Matrix. An incomplete product is
never written. The resulting `recursive-pass-audit.json` remains a separate
diagnostic fixture until a discovered pass or property is promoted into the
canonical Inspector/Matrix contract.

Accepted OS baselines, their build manifests, and the semantic comparison tool
live in [`Golden`](../Golden/README.md).

## Range and control policy

The editor distinguishes three meanings instead of treating every minimum and
maximum as a hard clamp:

1. **System metadata range** — authored by Core Animation and preferred when
   semantically useful, such as percentages and angles.
2. **Recipe range** — the observed system-Recipe envelope, including only
   validated size-formula extrapolation.
3. **Authoring range** — a useful manual-editing domain for declared-but-unused
   inputs or metadata that poorly describes live recipes.

Examples:

- Core Animation publishes `0...50` for Rim key/fill height, while measured
  recipes use 0.75...3.5; the editor uses the closer `0...5` domain.
- Metadata publishes `0...1` for `diffuseHeightScale`, while live recipes use
  8; the editor uses `0...10`.
- `CASDFOutputEffect.minimum = -10000` is a discrete Recipe sentinel.
  `inputMaxHeadroom` can likewise use the `9999` unbounded sentinel, but active
  same-build captures also resolve it to display-derived values such as `1.2`;
  Golden comparison therefore retains it raw and classifies it as volatile.

If a non-sentinel current or Override value escapes the selected envelope, the
slider expands around it and labels the range source `+Current`.
Runtime-discovered input keys join the proper semantic group automatically.
Declared-but-nil inputs display `nil` until explicitly authored.

## Compatibility and failure behavior

The target and public `NSGlassEffectView` API begin at macOS 26, but current
recipes and private inventories were measured on macOS 27 beta. Playground
access is capability-driven:

- fixed private APIs are used only after `responds(to:)`;
- dynamic filter values are accessed only when the current `inputKeys` contains
  the key;
- missing backdrop, filter, SDF layer, or effect passes produce guarded captures;
- nil values, absent fields, and absent passes remain distinguishable;
- Override writes to missing capabilities are no-ops.

This avoids unknown-key KVC crashes and lets individual fields disappear
without taking down the lab. It does not prove recipe parity on every macOS 26
build; a macOS 26 smoke test is still required.

## Current verification checklist

- Panel/Window + Main Off end at actual key=false, main=false.
- Panel/Window + Main On end at actual key=false, main=true while active.
- Desired Main On survives application deactivation and is reconciled after
  activation.
- Variant/Subvariant changes apply without a Host or Size nudge.
- Current values remain visible with Overrides locked.
- Enabling freezes the sampled supported values; disabling and re-enabling
  captures a fresh baseline.
- A controlled Panel probe captured the Main/Active appearance with both
  Overrides, returned the Panel to actual key=false/main=false, then focused
  another application; the locked material showed no visible change.
- Resetting an enabled Override restores its captured baseline.
- Export records only accepted contexts and restores the user's prior state.
- Xcode diagnostics remain clean after implementation changes.
