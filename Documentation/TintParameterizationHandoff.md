# Tint Parameterization Research Handoff

## Purpose

This document hands the macOS 27 Tint-parameterization investigation to a new
expert without requiring the preceding conversation. It records what the
captures actually prove, corrects an earlier overbroad conclusion, and defines
the remaining research boundary.

The product goal is to render a HUD with the certified Main-On glass
appearance even while its product window is not focused. The product must
support:

- Regular and Clear glass;
- authored visibility/strength;
- Light and Dark appearance;
- an optional muted semantic that may intentionally select Main-Off;
- continuously selectable Tint colors.

The question under investigation is whether an arbitrary Tint color can be
converted directly into the required `ColorMatrix4x5`, avoiding a live
per-color Main-On calibration.

## Correction: What Did and Did Not Fail

The earlier statement that “Tint colors cannot be parameterized” was not
supported by the evidence.

What failed was a particular class of candidate models: treating the captured
endpoint functions as globally smooth over sorted HSV coordinates and
reconstructing values between grid points with generic interpolation. That
does not prove that the underlying transform lacks a compact parameterization.

The captures are deterministic and strongly structured. They instead suggest
that one or more endpoint functions use piecewise gamut/headroom rules. A
smooth interpolator averages across those branches and therefore produces the
wrong result near their boundaries.

Do not make a product-architecture decision from the failed interpolation
alone.

## Evidence Files

All three datasets were captured on:

```text
macOS: Version 27.0 (Build 26A5388g)
Display: Studio Display XDR @2.0x
Atlas schema: 2
```

### Full Grid

Path:
`Golden/macOS-27/tint-parameterization-sweep.json`

```text
Plan: tint-parameterization-full-grid-v1
Colors: 170/170
Rows: 1,360
Complete: true
SHA-256: 16ff4af8dd05a7a975462e2d4806d817201adfe915e23ea408960895534a3120
```

This fixture is registered in `Golden/macOS-27/manifest.json`.

### Focused Phase 2b

Path:
`Golden/macOS-27/tint-parameterization-focused-phase-2b.json`

```text
Plan: tint-parameterization-focused-phase-2b
Colors: 131/131
Rows: 1,048
Complete: true
SHA-256: 37904f0b6911450c8c1876abaf00cf81a9b874c3c5bfbd03a7a2573e66f4bb92
```

This fixture is registered in `Golden/macOS-27/manifest.json`.

### Hue-Fraction Phase 2c

Path:
`Golden/macOS-27/tint-parameterization-hue-phase-2c.json`

```text
Plan: tint-parameterization-hue-fraction-phase-2c
Colors: 136/136
Rows: 1,088
Complete: true
SHA-256: 880668e22e1450cc3368a1cac4f169295488aae40b76303fb76ab9dba4fc1d15
```

This fixture is registered in `Golden/macOS-27/manifest.json`.

Across the three datasets there are 437 source colors and 3,496 captured rows.
Every document is complete. The analyzer reports zero structurally
unclassified rows and all capture hard gates pass.

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

Twelve Phase 2c colors repeat Full Grid coordinates across 96 cell rows. The
maximum difference across all matrix coefficients is exactly `0`. The three
files can therefore be analyzed together without evidence of session drift.

H17 and H137 are RGB-channel permutations at the same within-sector hue
fraction. After permuting output rows, their luma-endpoint matrices agree
within `2.7e-7`. This proves channel symmetry but does not provide two
independent hue-fraction samples.

## Established Matrix Structure

Tint is not an arbitrary 20-coefficient function per cell.

### Context selection

- Light Regular Main-On uses the standard luma-endpoint transform.
- Clear Main-On and Main-Off use the same standard transform in Light and
  Dark appearances.
- Dark Regular Main-On uses the pastel luma-endpoint transform for chromatic
  colors, although near-neutral convergence can make a bright-source heuristic
  label a row as standard.
- Light and Dark Regular Main-Off use color-independent neutral suppression.
- Exact or system-quantized achromatic inputs use the achromatic
  channel-affine transform in the six non-neutral cells.

The standard matrix is reused exactly across its five context cells. The
achromatic matrix is reused across all six non-neutral cells. Context
selection and color transformation should remain separate concerns in any
model.

### Alpha

Coefficient 18 is the source alpha. The fixed-RGB alpha sweep changes no other
coefficient.

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

Standard bright equals the source RGB at capture precision away from
near-neutral family convergence.

### Achromatic closed form

For an exact extended-sRGB gray value `x`:

```text
D = 1 + 0.05 × x × (1 - x)
diagonal = 0.3125 / D
bias = (1.1875 × x - 0.25) / D
```

Five gray values not used to derive the formula validate it with maximum
matrix residual `1.34e-7`. Achromatic Tint is parameterized successfully.

Phase 2c also resolves the family boundary:

```text
absolute chroma 0.0003 -> achromatic
absolute chroma 0.0004 -> chromatic
```

The result is identical at brightness 0.5 and 1.0, suggesting an
absolute-chroma threshold rather than an HSV-saturation threshold.

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

A tensor-product trilinear LUT over sorted `(S, V, hueFraction)` was then fit
to the complete high-brightness grid. Its maximum matrix-coefficient error on
the nine reserved colors was:

```text
0.0435507
```

Generic higher-order tensor interpolation reduced some individual errors but
still had a best observed maximum error of approximately:

```text
0.0393349
```

The provisional candidate threshold was `2e-4`, so these generic interpolators
do not qualify.

This is not evidence that all three endpoint functions are equally
unmodelled. For Salmon:

```text
pastel matrix error:  approximately 1.99e-7
standard matrix error: approximately 0.04355
```

The failure is dominated by `d_std` for this color. Other gamut-edge colors,
including Teal and Cyan, expose related branch-sensitive errors.

### Failed assumptions

The unsuccessful models assumed:

- endpoint values were globally smooth in sorted HSV coordinates;
- interpolation between sampled grid corners stayed on the correct system
  branch;
- low-degree hue-fraction behavior could be combined with ordinary S/V
  interpolation;
- a coefficient-space interpolation error directly answered the product's
  visual-equivalence question.

The captures contradict the first three assumptions near gamut/headroom
boundaries. The fourth assumption has not yet been validated: `2e-4` is an
engineering candidate threshold, not a measured perceptual limit.

## Piecewise-Branch Hypothesis

Several endpoint surfaces change direction as source colors approach full
brightness or as an output channel approaches 0, 1, or extended-sRGB
headroom. Some endpoints become negative or exceed 1. Linear interpolation
crosses the branch; high-order interpolation overshoots it because neither
method knows the branch predicate.

The unresolved hypothesis is that Apple first selects a region using a
gamut/headroom or perceptual-color constraint and then applies a simpler
formula inside that region.

Potential branch variables include:

- minimum, middle, and maximum source channel;
- absolute chroma and luma;
- a predicted endpoint channel crossing 0 or 1;
- extended-sRGB headroom;
- HSL/HSV lightness or value;
- a linear-RGB, Lab, or Oklab gamut boundary.

Do not assume that a near-neutral Dark Regular Main-On row labelled
`standard` proves a context-family change. The pastel bright endpoint may
simply converge close enough to the source to cross the analyzer's
`bright == source` classification tolerance.

## Safety and Scope Constraints

- Do not modify, normalize, clamp, or rewrite captured matrices.
- Keep all fitting in extended sRGB unless an explicit reversible color-space
  conversion is part of the tested model.
- Do not clamp negative endpoints or values above 1.
- Keep context-family selection separate from endpoint synthesis.
- Do not use the nine reserved colors to tune branch predicates or
  coefficients. They are final validation evidence.
- Do not capture another color grid until the existing branch surfaces have
  been exhausted analytically.
- Do not integrate a synthesis path into `GlassHUDMaterialController` before
  both matrix-space and rendered-output validation pass.
- A failed candidate model must fall back to the existing runtime Tint-lock
  path; it must never silently produce an approximate certified matrix.
- Product distribution is direct, not Mac App Store, but that does not relax
  fail-closed validation.

## Recommended Next Investigation

1. Write a reproducible analysis tool that loads all three fixtures, verifies
   their environment and repeat anchors, and extracts the three endpoint
   functions.
2. Analyze `d_std`, `p_bright`, and `p_dark` independently. Start with
   `d_std`, which dominates current holdout failures.
3. Plot each ordered output channel over `(S, V, hueFraction)` and locate
   derivative discontinuities rather than fitting one global surface.
4. For every discontinuity, test candidate predicates based on source channel
   extrema, luma/chroma, predicted output bounds, and perceptual-color gamut
   limits.
5. Fit the simplest formula separately inside each detected region.
6. Use the exact cross-session anchors to establish the numerical noise floor.
7. Lock the complete piecewise model before evaluating the nine reserved
   colors again.
8. Report per-function endpoint error, maximum matrix-coefficient error, and
   rendered pixel/perceptual error. Do not rely on coefficient error alone.
9. Only after this evaluation choose between:
   - direct parameter synthesis with a small certification anchor check; or
   - real-time preview followed by commit-time runtime Tint locking and bounded
     persistence.

No additional capture should be the default next step.

## Git and Worktree State

Branch:

```text
agent/tint-parameterization-study
```

Recent commits:

```text
d062b81 feat: add terminal tint hue sweep
66b39ed feat: classify achromatic tint matrices
b416481 fix: retain unclassified tint matrices
da43524 feat: add tint parameterization sweep
```

The publication commit contains only the handoff, the verified Phase 2c
fixture, and its manifest registration. The earlier research commits contain
the capture/analyzer implementation and the registered Full Grid and Phase 2b
fixtures.

```text
Documentation/TintParameterizationHandoff.md
Golden/macOS-27/manifest.json
Golden/macOS-27/tint-parameterization-hue-phase-2c.json
```

No unrelated worktree changes belong in the publication commit. The dedicated
branch is pushed independently; `main` must not be updated by this workflow.
