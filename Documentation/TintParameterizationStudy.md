# Tint Parameterization Study — Handoff Brief

Goal (follow-up declared in PR #3): determine whether the live Tint matrix can
be synthesized directly from a requested RGBA, eliminating per-color capture
and persistence so continuous color-picker interaction needs no
`lockingTint` phase. This brief records what has already been established
from existing data, what has been ruled out, and the concrete study that
remains. Read it fully before touching capture code — several hypotheses
were already tested and several dead ends are documented.

## Established structure (verified at two hues, two macOS majors)

All findings below were derived from data already in the repository and are
reproducible with the commands in *Data provenance*.

### 1. Nonzero chromatic Tint matrices are rank-1 in Rec.709 luma

Every hue-specific Tint `ColorMatrix4x5` observed so far has RGB rows of the
exact form

```
row_c = k_c × [0.2126, 0.7152, 0.0722] + bias_c        (c ∈ {r, g, b})
```

with per-row coefficient-ratio spread < 0.01% against the Rec.709 luma
weights. The alpha row is always `[0, 0, 0, α, 0]` where `α` is the requested
tint alpha exactly (coefficient 18; consistent with the AppKit RE doc). The
20-coefficient matrix therefore has 6 real degrees of freedom, fully
described by two endpoint colors:

- **bright endpoint** `k + bias` — the output color where backdrop luma = 1
- **dark endpoint** `bias` — the output color where backdrop luma = 0

The glass maps backdrop luminance onto a two-color gradient.

The first full-grid checkpoint on macOS 27 extended this result to all 144
nonzero chromatic grid colors across all eight cells. It also found the first
counterexample to treating the structure as universal: exact black
`gray-000`, Light Regular Main-On resolved a different structure
(`rank-1 residual 0.309601`). Exact black is therefore an explicit unknown
family or zero-color special case until its raw matrix and neighboring gray
samples are analyzed.

### 2. The standard transform: bright endpoint = the source color, exactly

For the standard (non-pastel) treatment, the bright endpoint equals the
requested tint RGB to capture precision, at both measured hues:

| source RGB | bright endpoint | dark endpoint |
|---|---|---|
| salmon (1.000, 0.450, 0.350) | (1.000, 0.450, 0.350) | (0.872, 0.001, −0.062) |
| coral (0.920, 0.180, 0.380) | (0.920, 0.180, 0.380) | (0.609, −0.027, 0.145) |

Only the **dark endpoint function `d_std(src)`** is unknown — 3 numbers per
color. Note the extended-sRGB negative components: fitting must not clamp.

### 3. The pastel transform (dark-appearance treatment)

A second transform exists whose endpoints are a lightened/pastel version of
the source:

| source RGB | bright endpoint | dark endpoint |
|---|---|---|
| salmon (1.000, 0.450, 0.350) | (0.982, 0.624, 0.559) | (1.003, 0.419, 0.313) |
| coral (0.920, 0.180, 0.380) | (0.911, 0.345, 0.498) | (0.922, 0.151, 0.359) |

Here **both** endpoint functions `p_bright(src)`, `p_dark(src)` are unknown.

### 4. The neutral suppression matrix contains no hue information

The hue-suppressed matrix (what a non-participating window resolves for
Regular) is exactly

```
0.70 × Identity + 0.30 × luma   (i.e. desaturate s = 0.30)
bias = +0.10 (dark appearance) / −0.10 (light appearance) on all three rows
alpha row = [0, 0, 0, α, 0]
```

completely independent of the requested RGB. Consequences: (a) the product
decision to fail closed on unverified tint was correct — the live fallback
carries zero hue; (b) **mapping Off→On is a dead end** — the Off matrix has
no hue information to map from. Direct RGB→matrix synthesis is the only
path.

### 5. Which transform applies where — this is what changed between majors

| cell | macOS 26 | macOS 27 |
|---|---|---|
| Light · Regular · Main-On | standard | standard |
| Light · Clear · Main-On | standard | standard |
| Dark · Regular · Main-On | **pastel** | **pastel** |
| Dark · Clear · Main-On | **pastel** | **standard** ← changed |
| Regular · Main-Off (both appearances) | neutral suppression | neutral suppression |
| Clear · Main-Off (both appearances) | neutral suppression | **standard, = Main-On** ← changed |

Two independent capture pipelines agree on the 27 behavior (the Golden
reference sweep and the PR #3 provider catalog), so the 27 rows are not a
capture artifact. The AppKit RE doc statements "Regular and Clear use the
same Tint matrix" and "Main Off suppresses tested hues into one neutral
matrix" were measured on 26.6 and are **stale for 27** (dark appearance
splits the variants; Clear no longer suppresses).

### 6. The endpoint functions themselves appear stable across majors

For the same source color, the standard endpoints are bit-identical between
macOS 26 and 27 (light cells), and the pastel endpoints are bit-identical
between 26-dark and 27-dark-regular. Working hypothesis: **the two color
transforms are fixed; only the per-cell transform selection changes per
major.** If the grid sweep confirms this, a fitted model survives OS majors
and only the (cheap, enumerable) selection table needs re-certification.

### 7. Visibility interaction is already understood

During Materialize only coefficient 18 changes, following
`sourceAlpha × inputFaceOpacity²` (verified in the Golden dynamic rows:
`a18` ramps 0.5 → 0.125 → ~0 for Coral·50%). Matrix synthesis does not need
to model `G`; the frozen writer already owns that scalar.

## Ruled out for the dark endpoint (two-point tests — do not re-derive)

- shared per-channel affine in sRGB (`dark_c = a·src_c + b`): inconsistent
  between the two hues
- per-channel proportional scaling in linear RGB: ratios differ wildly
  (0.72/0.0006/−0.05 vs 0.40/0.08/0.15)

Suggestive (not established): in HSB terms the standard dark endpoint looks
hue-preserving with saturation pushed slightly super-unit (~1.05) and
brightness scaled down by a source-dependent factor (salmon 0.872,
coral 0.662). Two points cannot pin the function — that is the study.

## Data provenance (all existing evidence)

- **salmon endpoints, all 8 cells**: the pre-strip PR #3 catalog —
  `git show a2499e3:LiquidGlassLab/GlassMaterial/Catalog/glass-macos-27.json`,
  `tintMatrices` (source (1.0, 0.45, 0.35, α 0.6), flat `[cellKey, entries]`
  pairs). Stripped from the shipped catalog on purpose; the history copy is
  the data.
- **coral endpoints, cross-version**: `Golden/macOS-26/unified/dynamic.json`
  and `Golden/macOS-27/unified/dynamic.json` — rows with
  `tint == "Coral · 50%"` (48 per version) carry resolved `ColorMatrix4x5`
  strings; parse with the regex in `Golden/tools/analyze-tint-study.mjs`.
  Rank-1 check: divide each RGB row by Rec.709 weights, require ratio spread
  < 1e-2, endpoints are `(k+bias, bias)`.
- **multi-alpha / Cyan presets**: `GlassLabTintPreset` in
  `LiquidGlassLab/GlassLab/GlassLabTintStudy.swift` (Coral 25/50/100%,
  Cyan 50%, Reduced variants). The historical `glass-tint-study.json`
  exports were never checked in and are lost — **persist every new dataset
  under `Golden/`** so this does not happen again.

## The study

### Implemented capture instrument

The existing Bench `Tint Study` page now includes a `Parameterization Sweep`
section rather than exposing a second Atlas-side study. Its full-grid v1 plan
captures 170 colors × 8 paired cells = 1,360 compact rows in one long-lived
probe session, writes an atomic checkpoint after every completed color, and
can resume the same OS-build/display-bound checkpoint. It does not call the
product's color-lock path or mutate the runtime Tint cache.

The plan contains the required 12 × 4 × 3 HSV grid, achromatic and very-dark
slices, exact Coral/Cyan historical anchors, and a fixed-RGB alpha sweep.
Each row is rejected unless the paired style samples prove genuine Main-On
participation and the source, alpha row, and 20 coefficients are complete.
Structure is evidence, not admission: luma-endpoint and neutral-suppression
rows are classified alongside the achromatic channel-affine family, while any
unfamiliar matrix is retained verbatim as `unclassified` with its residuals.
Legacy full-grid checkpoints that called the gray family `unclassified` remain
valid and are reclassified during analysis. Use
`Golden/tools/analyze-tint-parameterization.mjs` to re-run those gates and
summarize per-cell transform selection. No fitted RGB→matrix model is claimed
until a complete dataset has been captured and analyzed.

### macOS 27 full-grid result

The accepted `Golden/macOS-27/tint-parameterization-sweep.json` fixture covers
170 colors and 1,360 rows on build 26A5388g. All rows pass the capture gates and
all structures are now classified:

- six hue-carrying cells use one shared standard/pastel luma-endpoint matrix
  family;
- Regular Main-Off is a color-independent neutral-suppression family;
- exact grays use a shared channel-affine family in the six non-neutral cells;
- coefficient 18 carries alpha and the fixed-RGB alpha sweep changes no other
  coefficient.

For an achromatic extended-sRGB value `x`, the captured channel-affine matrix
is reconstructed at capture precision by:

```text
D = 1 + 0.05 × x × (1 - x)
diagonal = 0.3125 / D
bias = (1.1875 × x - 0.25) / D
```

The maximum residual across the 36 gray rows is `6.2e-8`. This is a model
candidate, not yet a product gate: all six original gray anchors participated
in deriving it.

### Focused Phase 2b result

The accepted `tint-parameterization-focused-phase-2b` fixture contains 131
colors and 1,048 fully classified rows: 80 samples densely cover the
high-brightness branch, 40 locate the low-saturation transition, five unseen
gray values validate the closed-form transform, and six arbitrary RGB colors
remain fit-independent holdouts.

The gray formula holds on all five unseen values with a maximum residual of
`1.34e-7`. Two `S=.001, V=.25` colors select the achromatic family, while the
same saturation at `V=.625` selects the chromatic family, bracketing the
absolute-chroma transition between `.00025` and `.000625`.

H17 and H137 are channel permutations at the same within-sector hue fraction,
and their luma-endpoint matrices agree after permutation within `2.7e-7`.
Consequently they prove channel symmetry but do not constrain arbitrary hue
fraction. Simple interpolation still misses the independent RGB holdouts by as
much as `8.1e-2`, so Phase 2b does not certify product synthesis.

### Hue-fraction Phase 2c plan

`tint-parameterization-hue-fraction-phase-2c` adds 136 colors. Its main 128
samples cover H0/H30/H45/H60 × four saturations × the same eight dense
high-brightness values. Combined with Phase 2b's H17 slice, every S/V
coordinate has five within-sector hue fractions. Eight additional probes
resolve the near-gray switch at absolute chroma `.0003...0006` under two
brightnesses. Run it from the Tint Study page or headlessly:

```sh
LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --capture-tint-parameterization-phase-2c \
  /path/to/tint-parameterization-hue-phase-2c.json
```

This is a decision gate, not the start of another open-ended sweep. The six
Phase 2b RGB holdouts plus the historical Coral/Cyan/Salmon anchors remain
excluded from fitting. Synthesis proceeds only if all nine stay within
`2e-4` maximum matrix-coefficient error and select the captured family;
otherwise the parameterized path is rejected and the product retains runtime
Tint locking.

1. **Grid sweep.** Reuse the paired-witness capture machinery
   (`GlassMaterialAtlasProvider.captureTintMatrices` and the Bench tint
   auto-lock in `GlassLabBenchAtlas.swift`) to sweep a color grid per cell:
   ≥ 12 hues × 4 saturations × 3 brightnesses, plus achromatic colors, very
   dark colors, gamut-edge colors (component 0 and 1), and an alpha sweep at
   fixed RGB to confirm alpha touches only coefficient 18. Export
   `(sourceColor → 8 cells × matrix)` as a Golden fixture
   (`Golden/macOS-27/tint-parameterization-sweep.json` + manifest entry).
2. **Structure classification.** For every captured matrix, require the alpha
   row and complete finite payload, then measure the rank-1 luma and neutral
   residuals. A structural violation invalidates the current candidate model
   for that row and must be retained and reported as `unclassified`, not
   smoothed over or used to abort the remaining evidence capture.
3. **Fit the three endpoint functions** (`d_std`, `p_bright`, `p_dark`).
   Try, in order: linear map in linear-RGB; affine map in linear-RGB;
   hue-preserving HSB scalar model; Oklab/Lab affine. Report residuals in
   both matrix-coefficient space and rendered-color space; residuals must be
   below capture noise (compare against repeat-capture variance, cf.
   `recursive-pass-audit-stability-repeat.json` methodology).
4. **Cross-version check.** Re-run a reduced grid on macOS 26 to confirm
   hypothesis (6): same transforms, different selection table. If false, the
   model becomes per-major and the certification gate below carries more
   weight.
5. **Certification gate (keep the fail-closed philosophy).** Synthesis is
   never trusted blind. Per macOS major, at first use, capture a small
   anchor set (3–5 colors) through the existing paired pipeline and compare
   synthesized vs resolved matrices; only on agreement does the controller
   enable the synthesis path, otherwise it falls back to today's per-color
   capture. Capture machinery is demoted to certification, not deleted.
6. **Product integration.** On success: `GlassHUDMaterialController` drops
   `lockingTint` for the synthesized path (status collapses to
   ready-with-tint immediately), the runtime tint cache and
   `mergeTintMatrices` shrink to anchor storage, and the color picker
   becomes fully continuous.

## Constraints and gotchas

- Extended sRGB: endpoints go negative and can exceed 1. No clamping
  anywhere in the fit or synthesis.
- `NSColor` equality and colorspace conversions: capture stamps
  `GlassMaterialColorValue` in extended sRGB; keep the fit in that space or
  convert explicitly.
- The witness-pair proof (`verifiesMainOn`) must keep gating every capture
  row: a contaminated Main-On sample poisons the fit silently.
- Dark-Regular pastel rows verify participation too — do not assume the
  standard transform when validating dark cells.
- All sweep output goes to `Golden/` with a manifest entry (sha256,
  entryCount, axes, notes), matching `Golden/CAPTURE-SPEC.md`.
