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

Every directory contains a `manifest.json` describing the exact OS build,
capture conditions, fixture schemas, entry counts, and SHA-256 checksums. A new
capture should replace a Golden only after its focus/activation conditions and
Cartesian-product coverage have been accepted.

The current macOS 27 baseline contains:

- `recipe-matrix.json`: the canonical active-session Main × Subdued × Variant
  × Subvariant × representative-Height sweep;
- `semantic-usage-trees.json`: all 24 SwiftUI Semantic Usage roles across real
  Main Off/On participation at one fixed geometry and Host;
- `formula-analysis.json`: derived envelopes and size formulas from the 426
  sample formula probe;
- `window-context-matrix.json`: the controlled 19-configuration host audit.

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
