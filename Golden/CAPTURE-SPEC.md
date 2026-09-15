# Golden Capture Specification

## Principle

The measured object is a resolved renderer state under declared conditions. One settled Static condition produces one complete typed `ResolvedSnapshot`. Scalar tables, recursive audit trees, topology signatures, and Consumer replay samples are pure projections of that Snapshot.

Dynamic transitions, Tint response matrices, and Semantic usage trees remain separate records because they measure time, color response, and view semantics rather than another encoding of one settled static tree.

The same schema reads the existing archives while the current writer emits the complete contract below. A missing `glassAmount` in historical evidence remains unknown; readers never silently substitute `0.5`.

## Static plan

The Swift plan is the sole authority for capture and Consumer coordinates. It declares ordinary typed contexts; there is no second JavaScript registry or requirements DSL.

The macOS 26 Full Static union contains exactly 776 unique coordinates:

```text
research core       672
research size        48
transposed size       8
corner radius        12
real key               4
product grid          56
product overlap      -24
                    ----
union                776
```

Exactly macOS 27 adds one sparse `glassAmount` axis to that same union. The original 776 rows become the explicit `0.5` baseline; overlapping coordinates are captured once:

```text
baseline                                      776
Consumer 0/0.5/1 anchors, net                 112
geometry: 17 sizes × 8 cells × 0/0.75/1, net 296
scale: 7 sizes × 8 cells × 11 amounts, net    448
quarter coverage, net                            56
non-Consumer sentinels, net                     16
Tint interaction                                40
Clear Main+Key midpoint boundary                 6
                                               ----
union                                          1750
```

The 17 geometry sizes are `{48, 64, 72, 80, 88, 96, 100, 104, 112, 120, 128, 136, 144, 152, 160, 200, 320}`. The scale slice uses sizes `{48, 64, 96, 120, 160, 200, 320}` and amounts `{0, .75, .8, .85, .875, .9, .925, .95, .975, .99, 1}`. Quarter coverage uses `.25/.75` at sizes `{48, 200, 320}` and `.25` at sizes `{72, 104, 112, 120}`.

The non-Consumer sentinels cover Variants 4/6 × Subdued off/on at amounts `{0, .25, .5, .75, 1}`. Tint interaction covers Coral 50 across the eight Consumer cells at the same five amounts. The Clear Main+Key Window boundary uses `{0, .0001, .4999, .5, .5001, 1}`.

The product grid is appearance `{Light, Dark}` × material `{Regular, Clear}` × participation `{Main Off, Main On}` × short side `{48, 64, 96, 128, 160, 200, 320}`. Every coordinate uses the canonical Panel host, Light backdrop, no Tint, and fixed 120-point window padding. On macOS 27 these 56 Consumer Catalog coordinates remain the explicit `0.5` subset. The stored condition records every controlled axis and the observed `shortSide`.

`glassAmount` is encoded only on exactly macOS 27. It is absent, rather than `null`, on macOS 26 and future unsupported majors. The capture-level provenance uses `processOverridePerObservation` with baseline `0.5`; it does not assert one amount for the whole archive.

Intentional stability is proven inside each occurrence by strict Snapshot settling, so the former 21-row second sweep is gone. A repeated observation is allowed only when the plan explicitly declares a distinct occurrence.

## Resolved Snapshot

A Snapshot recursively records layers and pass objects with stable paths/order, frame/bounds/position/anchor/transforms, opacity, colors, topology, and typed declared properties. CABackdropLayer `marginWidth` and `scale` are explicit replay-critical reads. A property state is exactly one of:

- `value` with a typed value;
- `nil` when the property is declared and resolves nil;
- `unreadable` when inspection is not possible.

Typed values include Bool, number, string, color with original color-space identity and extended-sRGB components, point, size, rect, matrix, array, dictionary, and an opaque description for research-only unknown values. Bool must be classified before `NSNumber` so it cannot silently become `0` or `1`.

Replay-critical fields may not be opaque or unreadable. The Consumer projection additionally requires exactly two ordered grade matrices, one supported rim, finite render bounds, explicit nil keys, structured colors, and the supported Regular/Clear topology. Research may retain opaque unknown leaves without making them replayable.

Stored topology/value signatures are forbidden; they are computed from the Snapshot when comparing.

## Settling and context

Each Static occurrence gets a fresh glass rebuild. The driver verifies requested appearance, Main/Key participation, host, app activation, and the active macOS 27 Glass coordinate after observation. It polls complete Snapshots every 100 ms for up to three seconds per rebuild, requires three consecutive equal reads, and cannot accept before the fresh view has existed for 800 ms. Exhaustion after five rebuilds fails that occurrence and prevents staging finalization. There are no tolerances, field exclusions, or pre-authorized unstable-property lists.

The same settled Snapshot serves all Static projections. There is no scalar sweep, recursive sweep, Style Atlas sweep, or GUI Catalog export.

## Other evidence domains

### Dynamic

The macOS 26 archive contains 104 runs with the exact nine-sample lifecycle:

```text
preflight(0), trigger(0), sample(.125/.25/.5/.75/.875), endpoint(1), settled(1)
```

macOS 27 retains those 104 baseline runs at amount `0.5`, adds 97 unique Linear runs from five amounts over 12 targeted conditions, and adds 72 System Default runs from three amounts over the same conditions, for 273 runs total. The 97 figure is the 120 requested Linear coordinates minus 23 baseline overlaps. `animationMode` participates in run identity.

Each insertion/removal pair is one physical lifecycle on the same renderer tree: the exact recorded insertion settled sample becomes removal preflight before removal is triggered. The pair must agree in both stable directions without tolerance. Backdrop and repeat sentinels retain their deliberate single-direction coverage. Every run records `requestedDuration`, actual `samplingDuration`, maximum attached animation duration, and the full capture context. Each sample stores one canonical native snapshot with model, presentation, model/presentation layer records, and attached animation timing/keyframe/spring facts. Compact filter/effect views are derived by readers and are not stored beside a duplicate raw payload.

Linear progress is sampled at the declared fractions. System Default records the renderer's time-based lifecycle over its observed attached duration (or the explicitly labeled sampling fallback); it does not claim that Settings-slider preview/commit easing has been measured. Elapsed time is finite and nondecreasing; observed progress remains scheduler-dependent.

### Tint

Tint is a first-class Golden measurement document outside Static Snapshot expansion because it measures a color-response matrix rather than another settled material coordinate. The three parameterization datasets and two resolution checks retain finite 4×5 matrices, exact color-space identity, paired proof, expected color×cell coverage, and build/display provenance. Checkpoint resume is accepted only within the same capture environment.

### Semantic

Semantic is a first-class Golden measurement document. It records 24 roles × Main Off/On at its fixed context. macOS 27 and later require 48 complete entries. macOS 26 has no Semantic document; that is a plan fact, not a compatibility exception.

Runtime notification/restamp, mutation, and rendered-pixel harnesses remain release validation because they measure process behavior or pixels rather than a reusable Static/Dynamic coordinate.

## Staging and promotion

`golden capture` writes partial/checkpoint data outside the requested final staging path. Only a complete admitted archive is atomically finalized as staging. Cancellation or any failed occurrence leaves accepted Golden untouched.

`golden promote` never launches the app. Preview compares and verifies the supplied staging. `--accept` re-admits that same staging, validates an install copy, then atomically creates or replaces `Golden/macOS-N`. Staged versus accepted is determined by location, not a JSON status field.

The admission contract is direct and small:

- required fixed files are readable JSON;
- capture provenance is complete and agrees across documents;
- Swift refuses to start unless its OS-specific plan has exactly 776/104 coordinates on macOS 26 or 1,750/273 on macOS 27, plus 56 Consumer coordinates; Static admission then requires unique complete Snapshots whose Consumer subset forms eight canonical projectable groups on one shared size grid;
- Dynamic lifecycle and pairing pass;
- Tint coverage and matrices pass;
- Semantic meets the per-major plan;
- learnings have no failures or undispositioned skips.

File inventories, SHA fields, Git cleanliness, report binding, canonical-path defenses, repeated-read race checks, profiles, module roles, and manifest compatibility are not part of this trusted-local workflow.

## Catalog projection

`golden catalog` reads accepted Golden only. It projects the 56 product coordinates into eight cells with seven ordered sizes, proves each Main-On sample against its same-context Main-Off witness, sets `tintMatrices` to an empty collection, decodes the result through the product schema, and writes canonical sorted-key JSON atomically.

Repeated generation from unchanged Golden must be byte-identical. `golden catalog --check`, Package tests, and a bundled-Provider read of a known value are the release checks. Golden promotion and Catalog generation remain two explicit intents; the Git commit/PR is their review boundary.
