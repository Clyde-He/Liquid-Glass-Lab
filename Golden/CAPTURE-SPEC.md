# Capture specification

What the exporter must produce, derived from the claims that have to be re-derivable — not from what the archive happens to contain today. If every fixture were deleted, this document is enough to rebuild the archive.

The unified archive is **three sections per OS, plus a meta file. Four files.** Nothing else belongs in `unified/`.

## The boundary

`unified/` holds exactly what is addressed by an **`NSGlassEffectView` cell** and is producible by **this** exporter: variant, subvariant, participation, appearance, geometry, host, and — for the dynamic section — transition progress.

Two things stay outside, each for its own reason, and each costs a claim the suite will not verify. Both costs are accepted.

**SwiftUI Semantic roles** — `_Glass.Variant.Role` is a different vocabulary that maps onto variants rather than being them. Folding it in would mean a `role` axis null on 95% of rows against a `variant` axis null on the rest. `semantic-usage-trees.json` stays a standalone fixture, and the claim that *Semantic Regular's 66 numeric values match AppKit raw 0/1* stays unverified. That is a P4 question about what Semantic is made of; the reference layer in `LiquidGlassLab/GlassMaterial` never touches the role space.

**The 19 controlled window conditions** — this codebase cannot reproduce them. That evidence came from a separate signed app-bundle probe that is not part of the lab; only its output survives, as `window-context-matrix.json`. It stays a standalone fixture, and the claim that *window class, style, level, opacity, shadow, and a spoofed `isKeyWindow` do not change the branch* stays unverified here. Re-deriving it means rebuilding that probe, which is out of scope for P1.

### Standalone Tint parameterization evidence

The RGB→Tint-matrix fitting sweep also stays outside `unified/`: it is a research dataset for deriving a color transform, not an `NSGlassEffectView` style catalog consumed at runtime. A complete per-major fixture contains 170 source colors × eight Light/Dark × Regular/Clear × Main-On/Off cells = 1,360 rows, each with the source extended-sRGB value, all 20 matrix coefficients, and its measured luma-endpoint, neutral-suppression, achromatic channel-affine, or `unclassified` structure plus residuals. An unfamiliar structure is retained evidence; it invalidates the current candidate model for that row, not the capture. Optional derived residual fields may expand as new families are understood without invalidating older checkpoints.

Capture writes an exact-build/display-bound checkpoint after every completed color so one dataset never silently mixes sessions. Once complete and validated by `Golden/tools/analyze-tint-parameterization.mjs`, promote it as `tint-parameterization-sweep.json` in the corresponding OS directory and add its SHA-256, 1,360 entry count, color/cell axes, and capture environment to that directory's manifest. Exact checkpoint identity is research provenance; it does not change the product Catalog's major-only compatibility rule.

Follow-up parameterization fixtures use the same admission and provenance rules and are registered separately rather than merged into the baseline JSON. Phase 2b keeps its arbitrary RGB colors as fit-independent holdouts; Phase 2c may constrain the model but must not absorb those holdouts. The combined macOS 27 model is accepted only when all nine reserved RGB anchors stay within `2e-4` maximum matrix-coefficient error and retain their captured family. Failure rejects synthesis and preserves runtime Tint locking.

What the exporter *can* produce is the load-bearing half of that finding: real key participation alone selects the active branch. That is the `key` slice below, and it is the half `GlassMaterialStrength` depends on, since it reads `isMainWindow || isKeyWindow`.

## Section 1 — `static-scalar`

Resolved shader inputs, rim projection, layer geometry, and colors. One row per cell. No trees.

### Core product — 672 rows

```text
21 variants × 4 subvariants × Main{off,on} × Subdued{off,on}
  × appearance{Light,Dark}
at 480 × 200, cornerRadius 16, Panel, Light backdrop, no tint, no overrides
```

Fixes the whole variant vocabulary at one reference geometry.

Appearance is an **axis** here, not a constant. Appearance moves resolved static values, so pinning it answers "which Variants follow appearance" for only half the vocabulary — and that question is what the accepted "appearance moves endpoints" finding rests on outside the two materials the dynamic section covers. The earlier archive recorded appearance as `null` because it was uncontrolled, and the first controlled capture differed from it on 240 of 336 cells: that difference *was* the appearance axis, discovered by accident.

### Axis slices — 72 rows

Slices exist because a claim needs an axis, not because the axis is interesting. Each runs on Variant 1 and 2, nil subvariant, Subdued off, unless noted.

| slice | values | rows | the claim it exists for |
| --- | --- | ---: | --- |
| size | 480 × {16, 24, 32, 48, 64, 80, 96, 128, 300, 400, 480, 600} | 48 | size formulas are proportional / capped / floored, and which |
| transposed size | {200×480, 400×480} | 8 | `shortSide = min(w, h)` is the only geometry variable |
| corner radius | {0, 8, 32} at 480×200 | 12 | corner radius reaches no shader input |
| real key | `key = true` on the Panel host, Main off, Subdued {off, on} | 4 | key alone selects the active branch, which is why `GlassMaterialStrength` reads `isMainWindow \|\| isKeyWindow` |

The size list is chosen to straddle every known cap: for Regular, inner refraction amount caps at −60 (crossing at short side 75 on macOS 26, 120 on macOS 27), inner refraction height at 20 (crossing at 80), and on macOS 27 outer refraction floors at 16 (crossing at 64) and the backdrop blur opacity is gated off below 64 then ramps to 0.8 by 160. A sweep that misses the crossing cannot tell a cap from a different ratio — which is exactly how the −0.8·S versus −0.5·S difference hid.

The dynamic section's three sizes are enough to *detect* these but not to locate a crossing. That is deliberate: the static sweep locates them cheaply at 12 sizes, and the dynamic section only has to confirm that the endpoint it reads matches the Recipe at the same cell.

Short side 200 is absent from the size slice because the core product already captures it at the reference geometry; a slice row there would collide on the cell coordinate. A learning fitting the size curve joins core and slice rows by cell, not by slice.

The key slice runs on the **Panel** host, not Window: a titled window that becomes key also becomes main, which would confound the two participation states the slice exists to separate. A panel can hold key alone. This is the one axis the harness actively forbade — every export path asserted `!isActuallyKey`, because the hard case it was built for is main-*without*-key — so it needs an explicit opt-in, now `state.isTestWindowKey`.

**Total: 744 rows, ≈ 2 MB.**

## Section 2 — `static-tree`

Recursive layer/pass/property inventory with topology and value signatures.

```text
core        336 rows   the static-scalar core at Light, same reference geometry
repeat       21 rows   variants × nil subvariant × Main on, captured a second
                       time in the same display session
appearance   21 rows   variants × nil subvariant × Main on, under DarkAqua
```

The tree is the expensive section, so appearance is a **slice** here rather than a second full product. It buys the whole variant vocabulary at one participation state, which is enough to answer the one question that matters — does topology follow appearance — and that question cannot be assumed: the dynamic section answers it for Variants 1 and 2 only.

The repeat is the direct capture's stability evidence for the static tree. It lands as additional rows on cells that already exist; the archive treats a repeated cell as evidence and never deduplicates.

Variant 4 is the measured adaptive exception: its `inputFaceColorMatrixBlack`, `inputFaceColorMatrixFillColor`, and `inputShadowColorMatrixFillColor` values may follow display adaptation between the two sweeps. Repeat comparison excludes only those three fields for that variant and still requires every other layer, pass, and property to agree.

**Total: 378 rows, ≈ 7 MB.**

## Section 3 — `dynamic`

Materialize and Dissolve sampled over progress. Regular and Clear only, nil subvariant — no other material is reachable from the public SwiftUI surface, and the curve ships for those two.

```text
core   2 materials × Main{off,on} × appearance{Light,Dark}
       × tint{none, Coral 50%} × direction{insertion,removal}
       × shortSide{48, 200, 400}                                    = 96 runs

backdrop slice   backdrop = Dark, at 200pt / Light appearance / no tint
                 / insertion, 2 materials × Main{off,on}            =  4 runs

repeat slice     re-capture the 200pt / Light appearance+backdrop /
                 no tint / insertion cells, 2 materials × Main      =  4 runs
```

Nine samples per run spanning `g = 0` to `g = 1`.

Every run gets a fresh transition-view identity. Insertion starts from a committed hidden subtree. Removal first performs a real Materialize In on a fresh hidden subtree, captures the same settled insertion endpoint used by an insertion run (100 ms after its animation endpoint), and immediately starts Materialize Out from that exact tree. It must not wait for the compact glass to adopt its later long-lived static face grade. This prevents a directly constructed Presented view, a coalesced false→true update, or an over-settled Recipe from standing in for the actual removal lifecycle. A completed removal has no `glassBackground`; that missing terminal tree is the observation of `g = 0`.

Backdrop is a slice rather than a full axis because it is *proven* not to reach model state — but the axis has to survive so the proof can be re-derived on the next OS. Deleting an axis whose finding is "this axis does nothing" destroys the finding.

**Total: 104 runs, 936 samples, ≈ 5 MB.**

## What each sample records

Model side only. `presentation`, `presentationLayers`, `modelLayers`, and the per-frame `animations` dictionary are not written: no accepted claim reads them and together they were 70% of the bytes.

Kept, because something reads it:

- filter name, path, layer class, location, and inputs as a `{key: value}` map;
- effect class, path, layer class, layer opacity, and inputs;
- `layerLines` — the SDF inflation claim parses element frames out of it;
- `maximumAttachedAnimationDuration` per run — the "no attached CAAnimation" claim rests on it;
- for static rows, the capability lists (`inputKeys`, `CA_attributes`) once per document rather than per row.

## Cell fields

`variant`, `subvariant`, `main`, `key`, `subdued`, `appearance`, `backdrop`, `tint`, `width`, `height`, `cornerRadius`, `host`, `direction`. `shortSide` is derived.

`key` is `false` on ordinary rows and `true` only on the static key slice.

A field is **null when the capture did not control that axis**. Adding a field later is backward compatible: rows written before it read as null, meaning uncontrolled, and every assertion keeps working. This is why the schema does not need to anticipate future axes.

The static sections sweep appearance and record their fixed Light backdrop. **Subdued** stays null on dynamic rows because SwiftUI exposes no such concept, and cross-section comparison must treat that null as compatible rather than false.

## Totals

| | rows | size |
| --- | ---: | ---: |
| `static-scalar` | 744 | ≈ 2 MB |
| `static-tree` | 378 | ≈ 7 MB |
| `dynamic` | 104 runs / 936 samples | ≈ 5 MB |
| **per OS** | | **≈ 14 MB, 4 files** |

Two OS directories: **8 files, ≈ 28 MB**, against today's 21 registered standalone fixtures and ≈129 MB. The current standalone count includes research, control, and derived evidence that is intentionally outside the unified payload.

## Retirement candidates

Direct export makes the following fixtures candidates for retirement, but emission alone is not a deletion gate. A fixture may be removed only after every consumer has migrated, v1/v2 resolution is equivalent, its hash and claims are recorded in [`evidence-retirement-ledger.json`](evidence-retirement-ledger.json), and every claim has an approved `coverage-replaced` or `claim-retired` disposition.

- `recipe-matrix.json` → `static-scalar` core plus the size slice
- `recursive-pass-audit.json` → `static-tree` core
- `recursive-pass-audit-stability-repeat.json` → `static-tree` repeat rows
- `recursive-pass-audit-display-context-a.json` → retained as reduced/control evidence until an explicit replacement preserves the display-context contrast claim
- `materialize-environment-matrix.json`, `materialize-geometry-sweep.json` → `dynamic`
- `formula-analysis.json` → retained until an equivalent reproducible generator and validation gate exist

Kept outside `unified/`:

- `semantic-usage-trees.json` — a different coordinate space;
- `window-context-matrix.json` — produced by a probe this codebase does not contain, so it cannot be re-captured or kept in sync.

Both are covered by the boundary section above.
