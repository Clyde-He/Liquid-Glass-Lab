# Capture specification

What the exporter must produce, derived from the claims that have to be
re-derivable — not from what the archive happens to contain today. If every
fixture were deleted, this document is enough to rebuild the archive.

The unified archive is **three sections per OS, plus a meta file. Four files.**
Nothing else belongs in `unified/`.

## The boundary

`unified/` holds exactly what is addressed by an **`NSGlassEffectView` cell**:
variant, subvariant, participation, appearance, geometry, host, and — for the
dynamic section — transition progress.

SwiftUI Semantic roles are deliberately **outside** it. `_Glass.Variant.Role`
tags are a different vocabulary that maps onto variants rather than being them;
folding them in would mean a `role` axis that is null on 95% of rows and a
`variant` axis that is null on the rest. `semantic-usage-trees.json` stays a
standalone fixture.

The cost of that line is explicit: the claim that *Semantic Regular's 66 numeric
values match AppKit raw 0/1* stays unverified by the suite. It is a P4 question
about what Semantic is made of, not a P1 question about the strength curve, and
the reference layer in `LiquidGlassLab/GlassMaterial` never touches the role
space.

## Section 1 — `static-scalar`

Resolved shader inputs, rim projection, layer geometry, and colors. One row per
cell. No trees.

### Core product — 336 rows

```text
21 variants × 4 subvariants × Main{off,on} × Subdued{off,on}
at 480 × 200, cornerRadius 16, Panel, no tint, no overrides
```

Fixes the whole variant vocabulary at one reference geometry.

### Axis slices — 95 rows

Slices exist because a claim needs an axis, not because the axis is
interesting. Each runs on Variant 1 and 2, nil subvariant, Subdued off, unless
noted.

| slice | values | rows | the claim it exists for |
| --- | --- | ---: | --- |
| size | 480 × {16, 24, 32, 48, 64, 80, 96, 128, 200, 300, 400, 480, 600} | 52 | size formulas are proportional / capped / floored, and which |
| transposed size | {200×480, 400×480} | 8 | `shortSide = min(w, h)` is the only geometry variable |
| corner radius | {0, 8, 32} at 480×200 | 12 | corner radius reaches no shader input |
| real key | `key = true`, Main off, Subdued {off, on} | 4 | key alone selects the active branch |
| window conditions | the 19 controlled host configurations | 19 | the branch follows real key-or-main, not window class, style, level, or a spoofed getter |

The size list is chosen to straddle every known cap: inner refraction amount
caps at −60 (crossing at short side 75 on macOS 26, 120 on macOS 27), inner
refraction height at 20 (crossing at 80), outer refraction floors at 16
(crossing at 64). A sweep that misses the crossing cannot tell a cap from a
different ratio — which is exactly how the −0.8·S versus −0.5·S difference hid.

**Total: 431 rows, ≈ 1 MB.**

## Section 2 — `static-tree`

Recursive layer/pass/property inventory with topology and value signatures.

```text
core     336 rows   same product as static-scalar, same reference geometry
repeat    21 rows   variants × nil subvariant × Main on, captured a second time
                    in the same display session
```

The repeat is the only cross-session stability evidence for the static tree.
It lands as additional rows on cells that already exist; the archive treats a
repeated cell as evidence and never deduplicates.

**Total: 357 rows, ≈ 7 MB.**

## Section 3 — `dynamic`

Materialize and Dissolve sampled over progress. Regular and Clear only, nil
subvariant — no other material is reachable from the public SwiftUI surface, and
the curve ships for those two.

```text
core   2 materials × Main{off,on} × appearance{Light,Dark}
       × tint{none, Coral 50%} × direction{insertion,removal}
       × shortSide{48, 200, 400}                                    = 96 runs

backdrop slice   backdrop = Dark, at 200pt / Light appearance / no tint
                 / insertion, 2 materials × Main{off,on}            =  4 runs
```

Nine samples per run spanning `g = 0` to `g = 1`.

Backdrop is a slice rather than a full axis because it is *proven* not to reach
model state — but the axis has to survive so the proof can be re-derived on the
next OS. Deleting an axis whose finding is "this axis does nothing" destroys the
finding.

**Total: 100 runs, 900 samples, ≈ 5 MB.**

## What each sample records

Model side only. `presentation`, `presentationLayers`, `modelLayers`, and the
per-frame `animations` dictionary are not written: no accepted claim reads them
and together they were 70% of the bytes.

Kept, because something reads it:

- filter name, path, layer class, location, and inputs as a `{key: value}` map;
- effect class, path, layer class, layer opacity, and inputs;
- `layerLines` — the SDF inflation claim parses element frames out of it;
- `maximumAttachedAnimationDuration` per run — the "no attached CAAnimation"
  claim rests on it;
- for static rows, the capability lists (`inputKeys`, `CA_attributes`) once per
  document rather than per row.

## Cell fields

`variant`, `subvariant`, `main`, `subdued`, `appearance`, `backdrop`, `tint`,
`width`, `height`, `cornerRadius`, `host`, `direction`, plus `key` and
`windowKind` for the window-condition slice. `shortSide` is derived.

A field is **null when the capture did not control that axis**. Adding a field
later is backward compatible: rows written before it read as null, meaning
uncontrolled, and every assertion keeps working. This is why the schema does not
need to anticipate future axes.

Two axes are currently null everywhere in the static sections and should be
recorded going forward, because their absence is what stops a settled `g = 1`
dynamic sample from being compared against its static Recipe row:

- **appearance** — the static sweeps capture whatever the machine was in;
- **subdued** on dynamic rows — SwiftUI exposes no such concept, so it stays
  null there, and the comparison must treat null as compatible.

## Totals

| | rows | size |
| --- | ---: | ---: |
| `static-scalar` | 431 | ≈ 1 MB |
| `static-tree` | 357 | ≈ 7 MB |
| `dynamic` | 100 runs / 900 samples | ≈ 5 MB |
| **per OS** | | **≈ 13 MB, 4 files** |

Two OS directories: **8 files, ≈ 26 MB**, against today's 11 source files and
138 MB.

## Retired on completion

Once the exporter emits these sections directly, these are deleted — their
evidence lives in the sections above:

- `recipe-matrix.json` → `static-scalar` core plus the size slice
- `recursive-pass-audit.json` → `static-tree` core
- `recursive-pass-audit-stability-repeat.json` → `static-tree` repeat rows
- `recursive-pass-audit-display-context-a.json` → not carried forward; it was
  provenance for a decision already made, and display context is not a cell axis
- `materialize-environment-matrix.json`, `materialize-geometry-sweep.json` →
  `dynamic`
- `window-context-matrix.json` → `static-scalar` window-condition slice
- `formula-analysis.json` → deleted. It is a computed report, not evidence;
  regenerate it from the size slice when needed

Kept outside `unified/`:

- `semantic-usage-trees.json` — a different coordinate space, see the boundary
  section above.
