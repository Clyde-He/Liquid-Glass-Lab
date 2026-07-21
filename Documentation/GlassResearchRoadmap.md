# Glass Research Roadmap

This document is the single backlog for unresolved Glass research. Verified
runtime behavior belongs in the two Reverse Engineering documents; lab UI and
export behavior belong in the Playground document. Items remain here until an
accepted capture, controlled mutation, or runtime trace turns them into
evidence.

- [AppKit Glass Reverse Engineering](./AppKitGlassReverseEngineering.md)
- [SwiftUI Glass Reverse Engineering](./SwiftUIGlassReverseEngineering.md)
- [Glass Lab Playground](./GlassLabPlayground.md)

## Scope and current decision

The lab studies the two relevant Liquid Glass authoring paths available to a
macOS application:

- AppKit `NSGlassEffectView`, which resolves a concrete Recipe into a relatively
  direct CAFilter/SDF composition;
- SwiftUI public `Glass` and private `_Glass`, which describe semantic intent
  and let SwiftUI build a larger environment-dependent composition.

They are distinct authoring pipelines, not necessarily distinct rendering
engines. Both reuse SwiftUICore/Core Animation primitives downstream. Classic
`NSVisualEffectView` materials remain useful fallbacks but are not part of this
Liquid Glass investigation.

The current research priorities are:

- keep `NSGlassEffectView` as the working AppKit reference backdrop;
- prioritize a curated Material Strength curve rather than a
  public surface containing every experimental Knob;
- AppKit completeness work may improve that curve but does not block its first
  iteration;
- SwiftUI private authoring research remains valuable but is explicitly
  non-blocking and low priority.

| Priority | Track | Current state |
|---|---|---|
| High | AppKit Material Strength curve | Not started |
| Medium | AppKit pass/Knob completeness and Aberration | Evidence collected; anomaly unresolved |
| Low | SwiftUI private authoring and resolved-pass control | Role inventory and fixed-context tree capture complete |
| Low | Cross-version and cross-platform comparison | macOS 27 baseline only |

## Track A — AppKit Material Strength curve

### Product question

A production HUD may need a continuous control that reduces the visual strength
of Glass without applying opacity to the already-composited view. Whole-view
opacity simultaneously destroys tint, blur, refraction, edge lighting, and
contrast; the desired control instead coordinates the material contributors
before final composition.

The user-facing model should stay small:

```text
Material Strength 0...1
          |
          +-- Face / Tint
          +-- Backdrop blur
          +-- Inner and outer refraction
          +-- Bleed / shadow
          +-- Filter highlight
          `-- Rim highlight and outer geometry
```

The curve must be designed perceptually. It is not assumed that every input is
linear, that every input reaches zero, or that all contributors should fade at
the same rate.

### Required baselines

Compare three implementations under identical geometry and content:

1. current whole-backdrop `alphaValue`;
2. the proposed AppKit Recipe-level Material Strength curve;
3. public SwiftUI `.regular`/`.clear` as a reference, not as an assumed winner.

Use the intended production HUD size plus at least one compact and one enlarged
surface.
Exercise static high-contrast text, saturated color boundaries, fine patterns,
and moving content behind the Glass. Capture the active Recipe that the final
surface intends to preserve before changing individual contributors.

### Curve experiment

Sample at minimum `0`, `0.125`, `0.25`, `0.5`, `0.75`, and `1`. For each point:

- record every authored Shader, Rim, and Geometry value;
- capture the rendered result against the same backdrop;
- verify that perceived strength changes monotonically;
- check for residual tint, blur, refraction, shadow, halo, or clipped reach at
  the zero endpoint;
- check for pass pop-in, hue shift, darkening, or a discontinuity at intermediate
  points;
- repeat after Main/focus changes and a resize that forces Recipe resolution.

Candidate groups should first be isolated one at a time, then combined. Do not
fit a global curve until the visual responsibility of each group is understood.

### Runtime and performance protocol

Static cost and animated-transition cost are separate measurements. Compare
the same surface area, display, backdrop content, Recipe, and HUD update rate.
Record at least:

- app CPU while HUD values update;
- render-server/WindowServer and GPU cost where Instruments exposes them;
- layer/pass inventory and unexpected layer replacement;
- frame pacing of the content behind the HUD;
- allocations or retained layer growth during repeated transitions.

Material writes must be event-driven. A production implementation may restamp
after a user setting change, Recipe/context rewrite, renderer replacement, or
geometry change. It must not rewrite Shader/Rim values on every FPS, CPU, or
other metric sample.

### Exit criteria

This track is complete when:

- strength `1` reproduces the accepted source Recipe;
- strength `0` has no visible material residue beyond the explicitly chosen
  transparent endpoint;
- intermediate points preserve a recognizable Glass response and feel
  continuous;
- focus/Main/resize cannot permanently replace the authored state;
- the chosen curve has a measured cost relative to whole-view alpha;
- a consumer can expose one strength control while keeping the low-level inputs
  an implementation detail.

## Track B — AppKit completeness

The current 77-key inventory is complete for the observed
`glassBackground` CAFilter. It is not yet proof that every visible contribution
inside `NSGlassEffectView` belongs to that one filter or to the separately
captured `CASDFKeyFillHighlightEffect`.

### Aberration anomaly

The accepted macOS 27 Recipe Golden contains:

- 1,008 total Recipe rows;
- 912 rows with a `glassBackground` Shader pass;
- 912 rows whose declared `inputKeys` contain all four Aberration inputs;
- zero rows that explicitly populate any of those four inputs.

The declared-but-nil inputs are:

- `inputAberrationAmount`;
- `inputAberrationHeight`;
- `inputAberrationOffset`;
- `inputAberrationAngle`.

This proves only that the sampled Recipe resolver did not leave explicit model-
side values in those fields. It does not prove that a visually observed color
separation is absent or that nil is equivalent to authored zero.

Unresolved hypotheses:

1. nil selects an internal/default shader value rather than numeric zero;
2. refraction, bleed, clamping, and color-matrix operations combine into an
   effect that looks like chromatic aberration;
3. another filter, effect, or intermediate layer produces the separation;
4. render-server state or backdrop-aware resolution is not reflected in the
   client-side model values;
5. a value is written transiently during Recipe resolution and disappears
   before the stable snapshot;
6. the observation depends on a particular high-contrast backdrop and is not
   visible in the current diagnostic content.

Experiment order:

1. identify and record the exact Variant, Subvariant, Main/Subdued state, size,
   appearance, display, and backdrop where the effect is visible;
2. compare each input at nil, explicit zero, and a clearly nonzero value while
   every other field is frozen;
3. capture all filters, background filters, compositing filters, SDF effects,
   masks, and relevant layer geometry across the complete AppKit Glass tree;
4. export complete `CA_attributes` entries, including default or identity
   values in addition to type and slider bounds;
5. trace `CAFilter setValue:forKey:` during Recipe resolution to detect
   transient writes or a second filter instance;
6. inspect the GraphicsFilter/provider/shader construction only if the prior
   observations cannot distinguish the hypotheses.

Promote an Aberration field into the Recipe curve only after a controlled
before/after image proves its contribution and its mutation lifetime is known.

### Complete pass and property inventory

- Recursively inventory `filters`, `backgroundFilters`, `compositingFilter`,
  masks, and object-backed `effect` values for every layer, not only the first
  `CABackdropLayer` and first Rim pass.
- Identify passes by class, filter name, role, and structural signature rather
  than fixed layer indexes.
- Capture declared type, subtype, authored range, default/identity value,
  resolved value, and nil/absent state independently.
- Establish whether each mutable object is live-mutable, copy-and-reassign, or
  replaced asynchronously by AppKit.
- Audit Objective-C properties/selectors and Swift symbols for Recipe inputs
  that never appear in the current UI.
- Compare representative real system Glass surfaces with lab-created variants
  to find tree or property families the integer/string Recipe axes do not reach.

### Remaining AppKit axes

- Sweep `Main × Subdued` across all 84 Variant/Subvariant Recipe cells; only
  Variants 0 and 2 currently have the controlled 2×2 capture.
- Determine whether AppKit attempts an intermediate inactive-app rewrite before
  the ordered Override restamp preserves the captured active appearance.
- Name the internal real key-or-main environment discriminator only if doing so
  unlocks behavior that controlled participation and restamping cannot provide.
- Capture a macOS 26 Golden and classify missing keys, changed ranges, changed
  pass topology, and fallback behavior against macOS 27.

## Track C — SwiftUI Glass research (deferred)

### Established foundation

The current macOS 27 evidence already provides:

- all 24 runtime-delivered `_Glass.Variant.Role` values;
- 48 fixed-context trees across real Main Off/On participation;
- the complete declared input inventory for every present CAFilter;
- observed SDF effect families and layer opacity changes;
- exact fixed-context overlap between many semantic roles and AppKit base
  `glassBackground` payloads;
- a versioned Golden comparator for future captures.

These facts make future work incremental. They do not yet establish a safe
private authoring API or a production-quality override mechanism.

### Authoring-level probes

Validate exact Swift calling conventions and copied-value behavior before
exposing any modifier. Then classify each successful probe by descriptor
change, resolved value change, pass opacity change, or graph-topology change.

Recommended order:

1. `forceActiveAppearance` and `forceSubdued`;
2. `disableOuterRefraction` and `disableEdgeBleed`;
3. `excludingForeground`, `excludingShadow`, and `excludingPlatter`;
4. `minimumDimension`, tint, `frost`, and `smoothness`;
5. `mix(with:by:)` between two already callable descriptors;
6. Text and Vibrant Fill factories;
7. interaction, accessibility, optimization, and specialized Siri options.

`frost`, `smoothness`, and `mix(with:by:)` have the highest potential relevance
because they may offer a coordinated descriptor-level strength control. They
should still be invoked only after their ABI is proven.

### Resolved-pass probes

If authoring-level controls are insufficient:

1. reuse the guarded 77-key schema for each present `glassBackground` pass;
2. establish mutation contracts for displacement and foreground filters;
3. decode `inputColorMatrix` as a complete typed 20-float matrix;
4. discover readable/writable properties for gradient, contour, shadow,
   displacement, highlight, and output effects;
5. relocate and restamp passes after SwiftUI graph replacement using structural
   identity rather than fixed indexes.

### Unresolved SwiftUI axes

- exact macOS 26 role, factory, and modifier availability;
- ABI and layouts for untested private nested types;
- role-by-role consumption of authoring modifiers;
- Size, Host, Shape, interaction, appearance, contrast, reduced transparency,
  and accessibility;
- complete color-matrix semantics and safe mutation ranges;
- writable properties for effects whose current inspector reports no inputs;
- whether an authored or resolved graph can survive every SwiftUI rebuild;
- iOS role availability, tag order, pass topology, values, and private ABI.

### Production renderer decision gate

SwiftUI should replace an AppKit backdrop only if a controlled comparison shows
that it can produce the desired continuous material fade with at most a small
number of authoring-level parameters, without resolved-pass restamping, and
with equal or better visual stability and measured runtime cost.

If equivalent control requires recursively overriding the multi-pass resolved
tree, SwiftUI remains a research renderer rather than a production renderer.

## Evidence and maintenance rules

- Record the OS version and build, architecture, display state, app activation,
  requested and actual key/main participation, Host, size, corner radius, and
  margin for every accepted capture.
- Reject automated visual captures made while the display/session is asleep or
  while requested and actual participation differ.
- Change one independent variable per mutation probe.
- Keep nil, absent key, absent pass, zero, and unavailable symbol as distinct
  states.
- Preserve raw Golden captures; derived classifications and fitted curves must
  be reproducible from them.
- A symbol name or metadata table is inventory evidence, not proof of a callable
  ABI, visual effect, safe range, or stable contract.
- Move a completed item into the appropriate Reverse Engineering document and
  remove its speculative wording from this roadmap.
