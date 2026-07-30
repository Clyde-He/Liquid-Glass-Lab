# Glass Lab Golden Standards

This directory keeps accepted Glass Lab captures in the repository so OS
releases can be compared without depending on `/tmp` probe artifacts. AppKit
Recipe and SwiftUI Semantic Usage remain separate fixtures because they are
different rendering pipelines and identifier spaces.

Measured renderer behavior is documented separately in
[`AppKitGlassReverseEngineering.md`](../Documentation/AppKitGlassReverseEngineering.md)
and
[`SwiftUIGlassReverseEngineering.md`](../Documentation/SwiftUIGlassReverseEngineering.md).
Open questions and future capture protocols are maintained in
[`GlassResearchRoadmap.md`](../Documentation/GlassResearchRoadmap.md).

## Layout

Each operating system gets an immutable directory named by its public major
version:

```text
Golden/
  learnings/    executable assertions, grouped by what they claim
  tools/        verifier, unifier, comparator, and per-study analyzers
  macOS-26/
    unified/    the three sections every learning reads
    *.json      the per-study capture fixtures they are derived from
  macOS-27/
```

What the exporter must produce, and why each axis exists, is specified in
[`CAPTURE-SPEC.md`](CAPTURE-SPEC.md). That document is derived from the claims
that have to stay re-derivable rather than from what the archive currently
holds, and it is the authority on what belongs in `unified/`.

## The unified archive

Every learning reads `<os>/unified/`, not the per-study fixtures. The three
sections there address rows by one shared **cell coordinate**, defined in
[`tools/lib/cell.mjs`](tools/lib/cell.mjs):

```text
variant · subvariant · main · key · subdued · appearance · backdrop · tint
        · width · height · cornerRadius · host · direction
```

| section | one row per | carries |
| --- | --- | --- |
| `static-scalar` | Recipe cell | resolved shader inputs, highlight, colors |
| `static-tree` | Recipe cell | recursive layer/pass inventory and signatures |
| `dynamic` | Materialize run | N progress samples of the model-side tree |

One coordinate for all three buys three things. Cross-version comparison
becomes a key match rather than a pairing routine written once per fixture.
Static and dynamic rows become directly comparable at one address. The
cross-section learnings then assert whether a Materialize `g = 1` endpoint and
the static Recipe actually agree; at 48pt the adaptive face grade proves that
address equality does not guarantee value equality. A new axis is a new field
rather than a new fixture format.

A cell field is **`null` when the capture did not control that axis** — not
false, not a default. The archived sweeps leave real holes: legacy derived
static sweeps may not record appearance, and the SwiftUI Materialize sweep has
no Subdued concept. Recording those as null is what makes a learning that needs
them skip loudly instead of passing by luck.

The sections committed under **both** `macOS-26/` and `macOS-27/` are now direct
**canonical** captures from the Lab exporter — 744 static-scalar rows, 378
static-tree rows, and 104 dynamic runs each. `unify.mjs` remains in the tree
because it is how a per-study fixture set is bridged into the unified contract
on a system the exporter has not yet run on:

```sh
node Golden/tools/unify.mjs <os-directory> --dry-run
node Golden/tools/unify.mjs <os-directory>
```

Nothing in the archive is transcoded today. Unified sections are committed so a
fresh clone can verify without a build step. The exporter writes the compact
contract without the presentation tree, structured layer dictionaries, or
animation branch, none of which any accepted learning reads.

Every OS directory contains a `manifest.json` describing the default OS build
and capture date, capture conditions, fixture schemas, entry counts, and
SHA-256 checksums. A new capture should replace a Golden only after its
focus/activation conditions and Cartesian-product coverage have been accepted.

Two manifest fields carry weight:

- **`platform`** may be set per fixture, overriding the directory default. This
  is not cosmetic — `macOS-27/` genuinely holds two builds, with the three
  recursive-pass-audit fixtures captured on `26A5388g` and the rest on
  `26A5378n`. `verify.mjs` fails when a fixture's embedded OS string disagrees
  with the entry filing it, so this cannot drift silently again.
- **`unifiedPlatform`** declares the build the `unified/` sections must carry,
  separately from `platform`, because a direct capture legitimately comes from a
  newer build than the source fixtures filed beside it — `macOS-27/` holds
  `26A5378n` fixtures under a `26A5388g` unified capture. `verify.mjs` fails when
  `unified/meta.json` disagrees, and the learnings are labelled with *this*
  build, since they read the unified sections and nothing else. Without it a
  unified archive dropped in from the wrong build verified fully green: the
  section checksums only prove each file matches its own meta entry.
- **`role`** separates `canonical` evidence from a `control` (a repeat or
  contrast kept as provenance) and from `derived` output computed off other
  fixtures. Only canonical fixtures should be cited as a result.

These are the source captures. Each one feeds a unified section, and which
section is recorded in `unified/meta.json` under `generatedFrom`.

The current macOS 27 directory contains:

- `recipe-matrix.json`: the canonical active-session Main × Subdued × Variant
  × Subvariant × representative-Height sweep;
- `recursive-pass-audit.json`: the accepted 336-row fixed-geometry recursive
  Layer/Pass/property inventory captured on build `26A5388g`;
- `recursive-pass-audit-stability-repeat.json`: the raw same-display-session
  repeat used to validate the canonical recursive fixture;
- `recursive-pass-audit-display-context-a.json`: an earlier raw contrast whose
  topology is stable but whose display-sensitive resolved values differ;
- `semantic-usage-trees.json`: all 24 SwiftUI Semantic Usage roles across real
  Main Off/On participation at one fixed geometry and Host;
- `formula-analysis.json`: derived envelopes and size formulas from the 426
  sample formula probe;
- `window-context-matrix.json`: the controlled 19-configuration host audit.

The current macOS 26 baseline is the direct canonical four-file archive:

- `unified/static-scalar.json`: 408 rows, including the 336-cell core plus
  size, transposed-size, corner-radius, and real-key slices;
- `unified/static-tree.json`: 357 rows, including 21 same-session repeats;
- `unified/dynamic.json`: 104 runs / 936 samples across Material,
  participation, appearance, backdrop, Tint, direction, and `shortSide`
  48/200/400;
- `unified/meta.json`: canonical provenance, hashes, slice counts, and the
  exact macOS build.

The dynamic section is the evidence behind P1's baseline-driven curve. It is
not a superset of the static sections: it covers only Variants 1 and 2 with a
nil subvariant, in exchange for appearance, backdrop, Tint, direction, size,
and progress axes the static products do not have.

The direct dynamic archive repeats four reference cells in the same capture
session. It keeps both copies rather than deduplicating, and a learning asserts
that their settled endpoints agree on every channel.

## Verifying the archive

One command checks file integrity and then re-derives every accepted learning
from the fixtures:

```sh
node Golden/tools/verify.mjs
```

Integrity covers manifest checksums, unregistered files, fixtures whose embedded
OS build disagrees with the manifest entry filing them, and the unified
sections' own checksums from `unified/meta.json`.

Learnings live in `Golden/learnings/` — each one is a finding from
`Documentation/` written as an executable assertion, naming the claim it encodes
and the document it came from.

```sh
node Golden/tools/verify.mjs --os macOS-27   # one directory
node Golden/tools/verify.mjs --verbose       # show each assertion
```

### Two kinds of learning

A **per-version** learning answers "does this hold on this OS". A
**cross-version** learning (`kind: "cross-version"`) receives every loaded
archive at once and answers a different question: *what changed, and does
`LiquidGlassLab/GlassMaterial` still hold*. Those are the ones that turn a
version bump into a work list. The current set checks that both versions address
the same cells, that the topology determinants and variant classes survived,
that no channel the strength curve classifies has vanished, and that the size
formulas kept their shape where their constants moved.

### Green means checked

A learning may report only three outcomes, and **a claim nothing checked must
never look like a claim that held**:

- **pass** — the assertion ran against real rows;
- **skip, section missing** — this OS has not captured what the learning reads;
- **skip, unverifiable** — the section exists but the axis the claim needs was
  never swept. The learning calls `expect.unverifiable(reason)` and the reason
  says what capture would settle it.

The third outcome exists because the earlier suite used an `ok(true, "not
present here")` escape hatch, and two learnings sat green for weeks having
verified nothing. Both are now honest skips, and both name the fix: sweep a
second corner radius, and add one transposed size pair so two rows share a short
side at different width and height.

Learnings assert **structure, not per-version values**. `inputInnerRefractionAmount`
is proportional-below-a-cap on both macOS 26 and 27, but the ratio differs
(-0.8·S versus -0.5·S), so the learning asserts the shape and reports the values.
A learning that hard-codes a measured constant will fail on the next OS for no
useful reason. The same rule kills universal ratios: 0.35·S bleed and 0.4·S
shadow height belong to the Variant 1 family, not to the material system —
Variant 9 resolves 0.071·S outer refraction and Variants 4, 5, and 11 are capped.

## Comparing an OS capture

Place the matching fixture in another OS directory and run:

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26
```

The comparator matches rows by their semantic axes instead of array order,
compares numeric values with a configurable tolerance, and reports missing
rows, new rows, missing fields, new fields, changed values, and volatile
environmental differences. Recipe rows use their context, Main, Subdued, Size,
Variant, and Subvariant identity. Semantic rows use their fixed document
environment plus `roleTag × requestedMain`; arrays are expanded to precise
layer/filter/effect fields instead of being reported as one opaque JSON change.

`inputs.inputMaxHeadroom` is retained in every raw fixture but reported
separately by default: same-build active captures changed between the `9999`
unbounded sentinel and display-derived `1.2` while all other comparable Shader,
Rim, and geometry values remained stable.

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --tolerance=0.000001 --limit=200
```

Pass `--include-volatile` when an investigation intentionally wants
`inputMaxHeadroom` included in the ordinary changed-value totals:

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --include-volatile
```

Compare the Semantic Usage fixture explicitly with:

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --fixture=semantic-usage-trees.json
```

Compare independently captured Recursive Pass Audits with:

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-26 \
  Golden/macOS-27 \
  --fixture=recursive-pass-audit.json
```

Recursive comparison defaults to `--recursive-mode=semantic`. It matches rows
by Recipe axes, groups passes by channel plus family, and pairs duplicate
families by owner-path and property-inventory similarity. The report separates
pass additions/removals, client-object and owner-class transitions, property
inventory changes, and resolved-value changes. Numeric descriptions honor the
requested tolerance, while nested `inputMaxHeadroom` remains classified as
volatile by default.

The semantic mode intentionally excludes raw Layer fields, structural IDs, and
whole-tree paths. Those remain available for exact same-build diagnostics:

```sh
node Golden/tools/compare.mjs \
  Golden/macOS-26 \
  Golden/macOS-27 \
  --fixture=recursive-pass-audit.json \
  --recursive-mode=raw
```

This distinction matters because a whole-tree wrapper changed between the
accepted macOS 26 and macOS 27 captures. Raw mode faithfully reports that
structural replacement; semantic mode prevents it from obscuring matched pass
families and property changes. Both modes still report the distinct topology
and value-signature counts plus raw changed-row totals.

Run the comparator integration coverage with:

```sh
node --test Golden/tools/compare.test.mjs \
  Golden/tools/unified-contract.test.mjs \
  Golden/tools/analyze-tint-parameterization.test.mjs
```

The contract tests exercise the direct-capture shape rather than the committed
derived fixtures: key identity, inferred axes, both Tint encodings, static-tree
repeat rows, and dynamic repeat provenance.

## Tint study analyzer

The Playground's Recipe `Tint` page exports one cross-renderer study containing
28 AppKit static rows, 20 SwiftUI static rows, and 40 Materialize runs / 360
samples. The raw document is intentionally kept as a local research artifact
until its schema and OS-repeat stability are promoted to a Golden fixture.

Analyze an export with:

```sh
node Golden/tools/analyze-tint-study.mjs /path/to/glass-tint-study.json
```

The report verifies count/context coverage and calculates:

- nil/nonnil AppKit topology and pass counts;
- public `tintColor` getter round-trip and AppKit/SwiftUI matrix parity;
- settled Tint-alpha coefficient routing and Main-Off hue suppression;
- Reduced Tint setter/getter capability rather than assuming a guarded no-op
  was an accepted material state;
- attached-animation count, Tint branch lifecycle, non-alpha coefficient
  stability, the `sourceAlpha × g²` fit, and Tint SDF-bounds residuals.

The accepted interpretation and current NSGlass transplant boundary live in
[`SwiftUIGlassReverseEngineering.md`](../Documentation/SwiftUIGlassReverseEngineering.md).

## Tint parameterization sweep

The Bench `Tint Study` page also exports the compact Phase 2 dataset used to
fit arbitrary RGB→Tint-matrix synthesis. Capture checkpoints contain 170
colors across all eight Light/Dark × Regular/Clear × Main-On/Off cells and can
be analyzed before or after completion:

```sh
node Golden/tools/analyze-tint-parameterization.mjs \
  /path/to/tint-parameterization-sweep.json
```

The analyzer revalidates source colors, alpha routing, finite matrix payloads,
eight-cell coverage, per-cell transform-family selection, and the fixed-RGB
alpha sweep. Rank-1 luma, neutral suppression, and achromatic channel-affine
matrices are classifications rather than admission gates; unfamiliar matrices
remain raw `unclassified` evidence and are reported as missing model coverage.
Legacy gray rows originally stored as `unclassified` are accepted and
reclassified without rewriting their captured matrices. Promote only a
complete, hard-gate-passing export into the matching `Golden/macOS-<major>/`
directory; the raw dataset is evidence for formula fitting, not a runtime
catalog.

## Core Recipe exporter

The Playground's `Export Recipe Matrix` produces the canonical OS baseline.
Its clean system sweep is:

```text
3 Heights × Main × Subdued × Variant × Subvariant = 1,008 entries
Width = 480
Height = 24 / 200 / 600
Corner Radius = 16
Scrim = false
Reduced Tint Opacity = false
Tint = nil
Overrides = disabled
```

Host and Window Margin are recorded as provenance, but they are not swept:
controlled probes ruled out Host as a direct Recipe selector, and Margin only
changes clipping room. The canonical matrix keeps small, normal, and
oversize/capped Height representatives. The separate formula analysis owns the
dense Height sweep as well as Width and Corner Radius controls and fitted
formulas, avoiding a sixfold Size multiplier on every routine OS capture.

The exporter writes only a complete active-session matrix: inactive capture
pauses and retries its current context, and requested/actual Main acceptance is
validated before the canonical `recipe-matrix.json` is replaced. A file with
fewer than 1,008 unique rows is not a Golden Standard even if its axes envelope
lists the full product.

## Recursive Pass Audit exporter

The Playground's `Export Recursive Pass Audit` keeps structural completeness
separate from the compact Recipe baseline:

```text
Main × Subdued × 21 Variants × 4 Subvariants = 336 entries
Width = 480
Height = 200
Corner Radius = 16
Host = Panel
Window Margin = 40
Scrim = false
Reduced Tint Opacity = false
Tint = nil
Overrides = disabled
```

Every snapshot walks sublayers and masks, then records direct filters,
background filters, compositing filters, and object-backed effects. Stable
structural paths key the JSON objects. Filter `inputKeys` and effect
`CA_attributes` keep capability separate from resolved `value`, `nil`, and
`unreadable` states. SHA-256 topology and value signatures make it cheap to
identify changed cells before reading precise nested diffs.

This fixture is diagnostic rather than automatically accepted. A first capture
should be repeated on the same build and in the same display session to
establish which layer fields and values are stable before it is added to an OS
manifest. The macOS 26 and macOS 27 fixtures have completed that review and are
listed in their manifests.

The accepted macOS 27 capture and its immediate repeat contain the same 336
rows, eight topology signatures, 60 value signatures, layer payloads, pass
inventories, and nonvolatile property values; only the top-level `capturedAt`
timestamp differs. An earlier capture around a display-context transition kept
the same topology and pass inventory but changed three resolved fields across
268 rows: `CASDFOutputEffect.maximum` plus the `DLCAFilter` `glassBackground`
inputs `inputKeyFillHighlightEffectOffset` and
`inputKeyFillHighlightHeight`. That capture is retained as provenance rather
than promoted to canonical.

## Semantic Usage exporter

The Playground's `Export All Usage Trees` produces the SwiftUI Semantic
baseline:

```text
24 runtime role tags × Main Off/On = 48 entries
Width = 480
Height = 200
Corner Radius = 16
Host = Panel
Window Margin = 40
```

Each row records runtime availability, requested and actual participation, the
flattened CA layer tree, CAFilter inventories and values, and object-backed SDF
effects. Export pauses while the application is inactive and writes only after
all available roles have snapshots, actual key remains false, and actual Main
matches the requested axis. Unavailable roles on an older runtime remain
explicit rows with no snapshot.

`CGColor.description` contains process-local object addresses, so the exporter
stores colors as stable color-space model plus ordered components. Structured
`NSValue` payloads such as `inputColorMatrix` are retained rather than stripped:
their byte descriptions contain material data, not pointer identity.
