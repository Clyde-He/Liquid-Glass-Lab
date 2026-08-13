# Golden Capture Specification

## Principle

The measured object is a resolved renderer state under declared conditions. One settled Static condition produces one complete typed `ResolvedSnapshot`. Scalar tables, recursive audit trees, topology signatures, and Consumer replay samples are pure projections of that Snapshot.

Dynamic transitions, Tint response matrices, and Semantic usage trees remain separate records because they measure time, color response, and view semantics rather than another encoding of one settled static tree.

There is no old-format reader or writer. macOS 26 and macOS 27 are freshly captured through this same contract.

## Static plan

The Swift plan is the sole authority for capture and Consumer coordinates. It declares ordinary typed contexts; there is no second JavaScript registry or requirements DSL.

The Full Static union contains exactly 776 unique coordinates:

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

The product grid is appearance `{Light, Dark}` × material `{Regular, Clear}` × participation `{Main Off, Main On}` × short side `{48, 64, 96, 128, 160, 200, 320}`. Every coordinate uses the canonical Panel host, Light backdrop, no Tint, and fixed 120-point window padding. The stored condition records every controlled axis and the observed `shortSide`.

Intentional stability is proven inside each occurrence by strict Snapshot settling, so the former 21-row second sweep is gone. A repeated observation is allowed only when the plan explicitly declares a distinct occurrence.

## Resolved Snapshot

A Snapshot recursively records layers and pass objects with stable paths/order, geometry, opacity, topology, and typed declared properties. A property state is exactly one of:

- `value` with a typed value;
- `nil` when the property is declared and resolves nil;
- `unreadable` when inspection is not possible.

Typed values include Bool, number, string, color with original color-space identity and extended-sRGB components, point, size, rect, matrix, array, dictionary, and an opaque description for research-only unknown values. Bool must be classified before `NSNumber` so it cannot silently become `0` or `1`.

Replay-critical fields may not be opaque or unreadable. The Consumer projection additionally requires exactly two ordered grade matrices, one supported rim, finite render bounds, explicit nil keys, structured colors, and the supported Regular/Clear topology. Research may retain opaque unknown leaves without making them replayable.

Stored topology/value signatures are forbidden; they are computed from the Snapshot when comparing.

## Settling and context

Each Static occurrence gets a fresh glass rebuild. The driver verifies requested appearance, Main/Key participation, host, and app activation before and after observation. It polls complete Snapshots with bounded `5 × 16` attempts and requires three consecutive equal reads. Exhaustion fails that occurrence and prevents staging finalization. There are no tolerances, field exclusions, or pre-authorized unstable-property lists.

The same settled Snapshot serves all Static projections. There is no scalar sweep, recursive sweep, Style Atlas sweep, or GUI Catalog export.

## Other evidence domains

### Dynamic

The archive contains 104 runs with the exact nine-sample lifecycle:

```text
preflight(0), trigger(0), sample(.125/.25/.5/.75/.875), endpoint(1), settled(1)
```

Each Core insertion/removal pair is one physical lifecycle on the same renderer tree: the exact recorded insertion settled sample becomes removal preflight before removal is triggered. The pair must agree in both stable directions without tolerance. Backdrop and repeat sentinels retain their deliberate single-direction coverage. Elapsed time is finite and nondecreasing; observed progress remains scheduler-dependent.

### Tint

Tint stays outside Static Snapshot expansion because thousands of mostly identical trees would obscure the actual measurement. The three parameterization datasets and two resolution checks retain finite 4×5 matrices, exact color-space identity, paired proof, expected color×cell coverage, and build/display provenance. Checkpoint resume is accepted only within the same capture environment.

### Semantic

Semantic records 24 roles × Main Off/On at its fixed context. macOS 27 and later require 48 complete entries. macOS 26 has no Semantic document; that is a plan fact, not a compatibility exception.

## Staging and promotion

`golden capture` writes partial/checkpoint data outside the requested final staging path. Only a complete admitted archive is atomically finalized as staging. Cancellation or any failed occurrence leaves accepted Golden untouched.

`golden promote` never launches the app. Preview compares and verifies the supplied staging. `--accept` re-admits that same staging, validates an install copy, then atomically creates or replaces `Golden/macOS-N`. Staged versus accepted is determined by location, not a JSON status field.

The admission contract is direct and small:

- required fixed files are readable JSON;
- capture provenance is complete and agrees across documents;
- Swift refuses to start unless its plan has exactly 776 unique coordinates and 56 Consumer coordinates; Static admission then requires unique complete Snapshots whose Consumer subset forms eight canonical projectable groups on one shared size grid;
- Dynamic lifecycle and pairing pass;
- Tint coverage and matrices pass;
- Semantic meets the per-major plan;
- learnings have no failures or undispositioned skips.

File inventories, SHA fields, Git cleanliness, report binding, canonical-path defenses, repeated-read race checks, profiles, module roles, carried-forward evidence, and manifest compatibility are not part of this trusted-local workflow.

## Catalog projection

`golden catalog` reads accepted Golden only. It projects the 56 product coordinates into eight cells with seven ordered sizes, proves each Main-On sample against its same-context Main-Off witness, sets `tintMatrices` to an empty collection, decodes the result through the product schema, and writes canonical sorted-key JSON atomically.

Repeated generation from unchanged Golden must be byte-identical. `golden catalog --check`, Package tests, and a bundled-Provider read of a known value are the release checks. Golden promotion and Catalog generation remain two explicit intents; the Git commit/PR is their review boundary.
