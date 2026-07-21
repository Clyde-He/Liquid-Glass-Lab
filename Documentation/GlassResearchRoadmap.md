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
| P0 | AppKit observed-pass completeness and control | Audits, semantic matcher, read-only Recursive Inspector, and live replacement tracking implemented; value classification and generic editor pending |
| P1 | Material Strength and system preset-curve research | Blocked on target-topology P0 closure |
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
exporter traversal, samples only while the Pass Inventory page is mounted, and
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

The curve is perceptual. It is not assumed that every property is linear, that
every channel reaches numeric zero, that all contributors start at the same
time, or that every Variant shares one curve.

P1 can start once the intended production Variant/topology has satisfied P0;
it does not wait for every theoretical private pass on every system surface.

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
   animation.

#### Capture protocol

For a controlled SwiftUI host and fixed Shape, size, backdrop, appearance, and
real window participation:

1. Insert and remove one Glass child inside `GlassEffectContainer` using
   `.materialize`.
2. Capture the system-default transaction, then repeat with an explicit linear
   transaction to separate transition mapping from outer animation timing.
3. Sample at normalized progress `0`, `0.125`, `0.25`, `0.5`, `0.75`, `0.875`,
   and `1`, with additional samples around any pass pop-in or inflection.
4. Record model and presentation layer trees, pass topology, every resolved
   filter/effect value, layer gates, transforms, blur, attached CAAnimation
   key paths, duration, timing functions, and keyframes.
5. Run insertion and removal independently; do not infer Dissolve by reversing
   Materialize samples.
6. Repeat with Reduce Motion enabled and with interrupted/reversed transitions.
7. Start with public Regular and Clear, then representative private roles whose
   resolved topologies differ: Regular, Menu, Camera, Siri, and a simple
   control/text role.
8. Normalize each changing channel and classify it as global, role-specific,
   direction-specific, gated, discrete, or unrelated to material strength.

The output should distinguish an endpoint preset, a timing function, and a
multi-channel material curve. Only the last category is a direct candidate for
reuse; endpoint and timing evidence can still seed an AppKit curve.

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

- the system Materialize/Dissolve behavior is classified as endpoint preset,
  timing curve, multi-channel curve, or a combination;
- role/Variant and direction dependence are known for the sampled domain;
- strength `1` reproduces the accepted source Recipe;
- strength `0` has no residue beyond the explicitly chosen endpoint;
- intermediate points remain continuous and recognizably Glass;
- context/resize reconstruction cannot permanently replace the authored state;
- runtime cost is measured against whole-view alpha;
- a consumer can expose one strength control while low-level pass inputs remain
  implementation detail.

## P2 — Recipe-axis closure

Complete only axes that can change topology, property capability, resolved
values, or Override reconstruction:

- rerun the existing candidate Subvariant strings (`popover`, `hud`, `window`,
  `toolbar`, `alert`, case/whitespace controls, and an unknown control) on
  macOS 26; promote a name only when it yields a repeatable signature distinct
  from nil;
- close targeted Height 24/600 cells selected by P0.6;
- determine whether inactive-app transitions write an intermediate Recipe
  before Override restamping;
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
