# Tint Parameterization Research Handoff

## Purpose

This document hands the macOS 27 Tint-parameterization investigation to a new expert without requiring the preceding conversation. It records what the captures actually prove, corrects an earlier overbroad conclusion, and defines the remaining product-acceptance boundary.

The product goal is to render a HUD with the certified Main-On glass appearance even while its product window is not focused. The product must support:

- Regular and Clear glass;
- authored visibility/strength;
- Light and Dark appearance;
- an optional muted semantic that may intentionally select Main-Off;
- continuously selectable Tint colors.

The question under investigation is whether an arbitrary Tint color can be converted directly into the required `ColorMatrix4x5`, avoiding a live per-color Main-On calibration.

## 2026-08-02 macOS 26/27 Display P3 outcome

The original handoff below certifies the extended-sRGB unit cube. The later per-major cold-start investigations extended that result to the complete Display P3 gamut without clamping the source color on macOS 26 and 27.

Only the out-of-unit `pastel` family was missing a rule. Applying the existing provisional endpoint and then these component-relative bounds reproduces the live system matrix:

```text
bright(x) = clamp(p_bright(x), -5x/12, (17 - 5x)/12)
dark(x)   = clamp(p_dark(x), 5x/4 - 1/4, 5x/4)
```

`Golden/macOS-27/tint-wide-gamut-model.json` contains 27 fixed Display P3 boundary colors and 24 predeclared Halton holdouts over all eight cells. All 408 rows pass paired proof and synchronous/settled equality; the worst model residual is `9.16e-7`, and the holdout-pastel maximum is `5.64e-7`.

`Golden/macOS-26/tint-wide-gamut-model.json` repeats the same plan on macOS 26.6. All 408 rows pass capture-integrity gates. Retaining the 26 family and context selection while enabling the same Display P3 bounds gives a maximum chromatic out-of-unit residual of `9.16e-7` and a maximum Halton-holdout residual of `5.63e-7`. The larger `6.57e-5` all-row maximum is confined to the already-certified 26 achromatic family and remains below its `2e-4` gate.

Product admission is gamut-shaped, not a loose extended-RGB range: source extended-sRGB values must round-trip through bounded Display P3 within the measured Float conversion tolerance. The macOS 26/27 runtime order is now certified model → exact compatible cache → legal-host resolver → wait. The exact cache remains a fallback for resolver-proven colors beyond Display P3; it is not the general P3 solution.

## Correction: What Did and Did Not Fail

The earlier statement that “Tint colors cannot be parameterized” was not supported by the evidence.

What failed was a particular class of candidate models: treating the captured endpoint functions as globally smooth over sorted HSV coordinates and reconstructing values between grid points with generic interpolation. That does not prove that the underlying transform lacks a compact parameterization.

The captures are deterministic and strongly structured. They instead suggest that one or more endpoint functions use piecewise gamut/headroom rules. A smooth interpolator averages across those branches and therefore produces the wrong result near their boundaries.

Do not make a product-architecture decision from the failed interpolation alone.

## Evidence Files

All three datasets were captured on:

```text
macOS: Version 27.0 (Build 26A5388g)
Display: Studio Display XDR @2.0x
Atlas schema: 2
```

### Full Grid

Path: `Golden/macOS-27/tint-parameterization-sweep.json`

```text
Plan: tint-parameterization-full-grid-v1
Colors: 170/170
Rows: 1,360
Complete: true
SHA-256: 16ff4af8dd05a7a975462e2d4806d817201adfe915e23ea408960895534a3120
```

This is the accepted `tint-parameterization-sweep.json` evidence document.

### Focused Phase 2b

Path: `Golden/macOS-27/tint-parameterization-focused-phase-2b.json`

```text
Plan: tint-parameterization-focused-phase-2b
Colors: 131/131
Rows: 1,048
Complete: true
SHA-256: 37904f0b6911450c8c1876abaf00cf81a9b874c3c5bfbd03a7a2573e66f4bb92
```

This is the accepted `tint-parameterization-focused-phase-2b.json` evidence document.

### Hue-Fraction Phase 2c

Path: `Golden/macOS-27/tint-parameterization-hue-phase-2c.json`

```text
Plan: tint-parameterization-hue-fraction-phase-2c
Colors: 136/136
Rows: 1,088
Complete: true
SHA-256: 880668e22e1450cc3368a1cac4f169295488aae40b76303fb76ab9dba4fc1d15
```

This is the accepted `tint-parameterization-hue-phase-2c.json` evidence document.

Across the three datasets there are 437 source colors and 3,496 captured rows. Every document is complete. The analyzer reports zero structurally unclassified rows and all capture hard gates pass.

Use:

```sh
node Golden/tools/analyze-tint-parameterization.mjs <dataset.json>
```

## Capture Integrity and Reproducibility

Every accepted row was gated on:

- genuine paired Main-On/Main-Off participation;
- the requested extended-sRGB source color;
- 20 finite matrix coefficients;
- the alpha-row contract;
- repeated stable reads.

Twelve Phase 2c colors repeat Full Grid coordinates across 96 cell rows. The maximum difference across all matrix coefficients is exactly `0`. The three files can therefore be analyzed together without evidence of session drift.

H17 and H137 are RGB-channel permutations at the same within-sector hue fraction. After permuting output rows, their luma-endpoint matrices agree within `2.7e-7`. This proves channel symmetry but does not provide two independent hue-fraction samples.

## Established Matrix Structure

Tint is not an arbitrary 20-coefficient function per cell.

### Context selection

- Light Regular Main-On uses the standard luma-endpoint transform.
- Clear Main-On and Main-Off use the same standard transform in Light and Dark appearances.
- Dark Regular Main-On uses the pastel luma-endpoint transform for chromatic colors, although near-neutral convergence can make a bright-source heuristic label a row as standard.
- Light and Dark Regular Main-Off use color-independent neutral suppression.
- Exact or system-quantized achromatic inputs use the achromatic channel-affine transform in the six non-neutral cells.

The standard matrix is reused exactly across its five context cells. The achromatic matrix is reused across all six non-neutral cells. Context selection and color transformation should remain separate concerns in any model.

### Alpha

Coefficient 18 is the source alpha. The fixed-RGB alpha sweep changes no other coefficient.

### Luma-endpoint representation

For a luma-endpoint matrix, each RGB output row is:

```text
output = Rec.709 luma × scale + darkEndpoint
brightEndpoint = scale + darkEndpoint
```

The chromatic problem therefore reduces to three endpoint functions:

- `d_std`: standard dark endpoint;
- `p_bright`: pastel bright endpoint;
- `p_dark`: pastel dark endpoint.

Standard bright equals the source RGB at capture precision away from near-neutral family convergence.

### Achromatic closed form

For an exact extended-sRGB gray value `x`:

```text
D = 1 + 0.05 × x × (1 - x)
diagonal = 0.3125 / D
bias = (1.1875 × x - 0.25) / D
```

Five gray values not used to derive the formula validate it with maximum matrix residual `1.34e-7`. Achromatic Tint is parameterized successfully.

Phase 2c also resolves the family boundary:

```text
absolute chroma 0.0003 -> achromatic
absolute chroma 0.0004 -> chromatic
```

The result is identical at brightness 0.5 and 1.0, suggesting an absolute-chroma threshold rather than an HSV-saturation threshold.

## Resolved macOS 27 Closed Form

The three chromatic endpoint functions are now parameterized. This is a piecewise HSL-lightness transform in extended sRGB, not a generic fitted LUT.

For source component `x`, define:

```text
m = min(r, g, b)
M = max(r, g, b)
C = M - m
L = (M + m) / 2
t(x) = (x - m) / C
```

### Standard dark endpoint

```text
f_std(L) =
    57/85                                           L <= 1/2
    ((87/5)L - 3) / (17(1 - L))                    1/2 < L <= 5/6
    (21/17 - (57/85)L) / (1 - L)                   L > 5/6

provisional(x) = (9/17)L + f_std(L)(x - L)
lower(x) = -3x/17
upper(x) = (20 - 3x)/17

d_std(x) = min(max(provisional(x), lower(x)), upper(x))
```

The last line is not a conventional `[0, 1]` clamp. Its component-dependent bounds preserve the captured negative and above-one extended-sRGB values.

### Pastel bright endpoint

```text
L_bright(L) =
    (137/120)L                                      L <= 10/11
    17/12 - (5/12)L                                L > 10/11

f_bright(L) =
    851/800                                         L <= 5/11
    -4553/2400 + (323/240)/L                       5/11 < L <= 1/2
    (223/240 - (851/800)L) / (1 - L)               1/2 < L <= 10/11
    -5/12                                           L > 10/11

p_bright(x) = L_bright(L) + C f_bright(L)(t(x) - 1/2)
```

### Pastel dark endpoint

```text
L_dark(L) =
    (39/40)L                                        L <= 10/11
    (5/4)L - 1/4                                   L > 10/11

f_dark(L) =
    791/800                                         L <= 5/11
    1209/800 - (19/80)/L                           5/11 < L <= 1/2
    (81/80 - (791/800)L) / (1 - L)                 1/2 < L <= 10/11
    5/4                                             L > 10/11

p_dark(x) = L_dark(L) + C f_dark(L)(t(x) - 1/2)
```

### Matrix reconstruction

For each RGB output row:

```text
scale = brightEndpoint - darkEndpoint
RGB coefficients = scale × [0.2126, 0.7152, 0.0722]
bias = darkEndpoint
```

Coefficient 18 is source alpha. Context family selection is semantic:

- Dark Regular Main-On uses pastel;
- the other five chromatic luma-endpoint cells use standard;
- Regular Main-Off uses neutral suppression;
- absolute chroma at or below the measured boundary uses the achromatic formula.

Do not infer the family from `bright ≈ source`; near-white pastel rows converge inside that heuristic tolerance and are otherwise misclassified.

### Validation

`GlassMaterialTintMatrixSynthesizer` and the Golden analyzer independently rebuild the complete matrix. Across 437 colors and all 3,496 context rows:

```text
all rows above the supported achromatic boundary: pass 2e-4
worst complete-matrix residual: 1.963824e-4
worst row: boundary-c0600-v1000 · Light · Regular · Main-On
pastel-bright endpoint maximum: approximately 5.2e-7
pastel-dark endpoint maximum: approximately 1.6e-7
fit-independent RGB holdout maximum: below 5e-7 on luma-endpoint rows
```

The worst row is the intentionally adversarial chroma-`0.0006` boundary sample. The 99th percentile complete-matrix residual is approximately `2.1e-6`. No per-color matrix cache is required inside this original unit-domain model; the later Display P3 extension above has the same property.

### Rendered acceptance

The coefficient gate is now backed by a controlled rendered A/B test through the actual AppKit glass renderer. The test covers eight risk colors across all eight Light/Dark × Regular/Clear × Main-On/Main-Off contexts, for 64 rows:

- exact black and mid gray;
- the independent Salmon and Teal holdouts;
- a gamut-edge red;
- absolute-chroma boundary probes at `0.0003`, `0.0004`, and `0.0006`.

For every row the harness records the system-resolved matrix, captures an A/A pair without changing the matrix, writes the synthesized matrix onto the same live Tint layer, verifies the matrix readback, and captures A/B. It uses `ScreenCaptureKit` with `SCShareableContent.currentProcess`, so it exercises WindowServer output without requiring screen-recording permission.

The final macOS 27 run passed all 64 rows:

```text
rows: 64/64
maximum live matrix residual: 1.963973e-4
maximum A/A RGB code delta: 3
maximum synthesized A/B RGB code delta: 3
failures: 0
```

The matrix gate remains `2e-4`, and synthesized-matrix readback must remain within `1e-6`. The pixel gate is calibrated against the per-row A/A control:

```text
A/A: max <= 4, p99 <= 1, RMS <= 0.5 RGB code values
A/B: max <= max(4, A/A max + 1)
     p99 <= max(1, A/A p99 + 1)
     RMS <= max(0.25, A/A RMS + 0.15)
```

Up to three pixel attempts may reject transient WindowServer noise; the matrix gate is never retried away. A stricter `max <= 2` pixel gate was shown invalid because a bit-identical captured/captured Main-Off control produced a maximum delta of 3. The retained p99 and RMS limits prevent isolated compositor noise from becoming a broad visual-tolerance exemption.

## Parameterization Attempts and Results

The high-brightness combined grid supplies:

```text
S: 0.25, 0.5, 0.75, 1.0
V: 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.98, 1.0
within-sector hue fraction: 0, 17/60, 0.5, 0.75, 1.0
```

Nine colors were kept outside fitting:

- historical Coral;
- historical Cyan;
- Salmon at alpha 0.5;
- six Phase 2b `rgb-holdout-*` colors.

### Models already shown inadequate

Earlier exploratory work also rejected simple global affine maps in sRGB:

```text
standard dark endpoint RMSE: approximately 0.151
pastel bright endpoint RMSE: approximately 0.0468
pastel dark endpoint RMSE: approximately 0.00827
```

A tensor-product trilinear LUT over sorted `(S, V, hueFraction)` was then fit to the complete high-brightness grid. Its maximum matrix-coefficient error on the nine reserved colors was:

```text
0.0435507
```

Generic higher-order tensor interpolation reduced some individual errors but still had a best observed maximum error of approximately:

```text
0.0393349
```

The provisional candidate threshold was `2e-4`, so these generic interpolators do not qualify.

This is not evidence that all three endpoint functions are equally unmodelled. For Salmon:

```text
pastel matrix error:  approximately 1.99e-7
standard matrix error: approximately 0.04355
```

The failure is dominated by `d_std` for this color. Other gamut-edge colors, including Teal and Cyan, expose related branch-sensitive errors.

### Failed assumptions

The unsuccessful models assumed:

- endpoint values were globally smooth in sorted HSV coordinates;
- interpolation between sampled grid corners stayed on the correct system branch;
- low-degree hue-fraction behavior could be combined with ordinary S/V interpolation;
- a coefficient-space interpolation error directly answered the product's visual-equivalence question.

The captures contradict the first three assumptions near gamut/headroom boundaries. The fourth assumption is now answered independently rather than assumed: the 64-row rendered A/B passed with the candidate matrices, while the A/A control established the screenshot noise floor. The `2e-4` coefficient gate is therefore retained as a structural gate, not treated as a standalone perceptual metric.

## Why Generic Interpolation Failed

Several endpoint surfaces change direction as source colors approach full brightness or as an output channel approaches 0, 1, or extended-sRGB headroom. Some endpoints become negative or exceed 1. Linear interpolation crosses the branch; high-order interpolation overshoots it because neither method knows the branch predicate.

The branch variables are now established: HSL lightness at `5/11`, `1/2`, `5/6`, and `10/11`, plus the component-dependent standard bounds above. Generic interpolation crossed these exact predicates and averaged different formula regions.

Do not assume that a near-neutral Dark Regular Main-On row labelled `standard` proves a context-family change. The pastel bright endpoint may simply converge close enough to the source to cross the analyzer's `bright == source` classification tolerance.

## Safety and Scope Constraints

- Do not modify, normalize, clamp, or rewrite captured matrices.
- Keep all fitting in extended sRGB unless an explicit reversible color-space conversion is part of the tested model.
- Do not clamp negative endpoints or values above 1.
- Keep context-family selection separate from endpoint synthesis.
- Do not use the nine reserved colors to tune branch predicates or coefficients. They are final validation evidence.
- Do not capture another color grid until the existing branch surfaces have been exhausted analytically.
- Do not integrate a synthesis path into `GlassEffectController` before both matrix-space and rendered-output validation pass.
- A failed candidate model must fall back to the existing runtime Tint-lock path; it must never silently produce an approximate certified matrix.
- Product distribution is direct, not Mac App Store, but that does not relax fail-closed validation.

## Product Integration Status

Both matrix-space and rendered-output acceptance pass on macOS 27, and `GlassEffectController` now uses the result:

1. On macOS 26 and 27, each configuration update synthesizes the four matrices needed by the selected Normal/Muted participation into an in-memory Atlas copy for any color in the certified Display P3 domain. The closed-form path does not mutate or persist the Provider Atlas, and cached matrices cannot override it.
2. A complete commit-resolved eight-cell set outside that domain is separately promoted to the bounded, exact-RGB, major-scoped runtime Tint overlay.
3. `lockingTint` remains only as a fail-closed fallback for unsupported system majors or colors outside the certified synthesis input domain.
4. Both supported majors have complete Display P3 boundary/holdout certification. Exact cache/live resolution remains the fallback beyond Display P3.

No additional Display P3 color grid is required by the current evidence.

## Git and Worktree State

Branch:

```text
agent/tint-parameterization-study
```

Recent commits:

```text
8cce87f docs: publish tint parameterization research handoff
d062b81 feat: add terminal tint hue sweep
66b39ed feat: classify achromatic tint matrices
b416481 fix: retain unclassified tint matrices
da43524 feat: add tint parameterization sweep
```

The publication commit `8cce87f` contains only the handoff and verified Phase 2c evidence. The earlier research commits contain the capture/analyzer implementation and the Full Grid and Phase 2b evidence.

```text
Documentation/TintParameterizationHandoff.md
Golden/macOS-27/tint-parameterization-hue-phase-2c.json
```

The closed-form and rendered-acceptance work after `8cce87f` consists of:

```text
Documentation/GlassLabPlayground.md
Documentation/TintParameterizationHandoff.md
Documentation/TintParameterizationStudy.md
Golden/README.md
Golden/tools/analyze-tint-parameterization.mjs
Golden/tools/analyze-tint-parameterization.test.mjs
LiquidGlassLab/GlassLab/GlassLabBenchHeadless.swift
LiquidGlassLab/GlassLab/GlassLabBenchTintStudy.swift
LiquidGlassLab/GlassLab/GlassLabTintParameterizationSweep.swift
LiquidGlassLab/GlassLab/GlassLabTintRenderedAB.swift
LiquidGlassLab/GlassLab/GlassLabView.swift
LiquidGlassLab/GlassMaterial/GlassEffectController.swift
LiquidGlassLab/GlassMaterial/GlassMaterialAtlas.swift
LiquidGlassLab/GlassMaterial/GlassMaterialStrength.swift
LiquidGlassLab/GlassMaterial/GlassMaterialTintMatrixSynthesizer.swift
LiquidGlassLab/GlassMaterial/README.md
Tests/AdjustableGlassTests/TintMatrixSynthesizerTests.swift
```

At the time of this handoff update, these files are intentionally uncommitted. `LiquidGlassLab.xcodeproj/project.pbxproj` also has an unrelated Xcode formatting-only worktree diff and must not be included with the research. The dedicated branch is pushed independently; `main` must not be updated by this workflow.

## Postscript: macOS 26 Certification

The cross-version investigation recommended above was subsequently executed in full on a macOS 26.6 host. The complete Full Grid, Phase 2b, and Phase 2c plans (3,496 rows, registered under `Golden/macOS-26/`) confirmed:

- the standard and pastel endpoint transforms are unchanged at float precision (all 26 rows are out-of-sample for the 27-fitted formulas; reserved rgb-holdouts resolve within 2.5e-7);
- the achromatic/chromatic boundary is identical (0.0003 vs 0.0004);
- the neutral suppression coefficients are bit-identical, and on 26 they additionally apply to Clear Main-Off;
- macOS 26 selects pastel for both Dark Main-On variants and resolves a distinct achromatic family, the saturation complement `I − (0.9 + 0.05x)·(1⊗w)` with `bias = 0.95x` (gray-holdout residual 6.6e-5).

`GlassMaterialTintMatrixSynthesizer` now carries both majors with per-major context selection; see `Documentation/TintParameterizationStudy.md` for the certified model statement.
