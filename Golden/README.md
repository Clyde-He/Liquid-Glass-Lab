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
  macOS-26/
  macOS-27/
```

Every directory contains a `manifest.json` describing the default OS build and
capture date, capture conditions, fixture schemas, entry counts, and SHA-256
checksums. Fixture-level `platform` and `capturedAt` fields override those
defaults when a later seed is captured without relabelling older fixtures in
the same major-version directory. A new capture should replace a Golden only
after its focus/activation conditions and Cartesian-product coverage have been
accepted.

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

The current macOS 26 baseline contains:

- `recipe-matrix.json`: the accepted 1,008-row representative-height Recipe
  product;
- `recursive-pass-audit.json`: the accepted 336-row fixed-geometry recursive
  Layer/Pass/property inventory.

## Comparing an OS capture

Place the matching fixture in another OS directory and run:

```sh
node Golden/compare.mjs \
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
node Golden/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --tolerance=0.000001 --limit=200
```

Pass `--include-volatile` when an investigation intentionally wants
`inputMaxHeadroom` included in the ordinary changed-value totals:

```sh
node Golden/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --include-volatile
```

Compare the Semantic Usage fixture explicitly with:

```sh
node Golden/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --fixture=semantic-usage-trees.json
```

Compare independently captured Recursive Pass Audits with:

```sh
node Golden/compare.mjs \
  Golden/macOS-27 \
  Golden/macOS-26 \
  --fixture=recursive-pass-audit.json
```

For this fixture the summary also reports distinct topology/value signature
counts and the number of matched rows whose signatures changed. The hashes are
not repeated as opaque ordinary differences; field diffs descend through the
stable layer/pass/property dictionary keys. Nested `inputMaxHeadroom` remains
classified as volatile by default. A whole-tree structural wrapper changed
between the accepted macOS 26 and macOS 27 captures, so raw structural-path
totals are intentionally conservative; pass-family and property-key parity
still requires semantic classification rather than equating array/path
positions across releases.

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
