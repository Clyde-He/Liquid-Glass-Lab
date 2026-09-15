# Glass Lab Golden

`Golden` is the repository's accepted record of measured macOS glass behavior. Each supported macOS major has one directory, one schema, and one acquisition path. The Consumer Catalog is generated from those accepted measurements; it is never captured separately.

The detailed coordinate and payload contract lives in [`CAPTURE-SPEC.md`](CAPTURE-SPEC.md). Measured conclusions remain in [`Documentation`](../Documentation), with executable assertions in [`learnings`](learnings).

## Archive shape

```text
Golden/
  macOS-26/
    capture.json
    static.json
    dynamic.json
    tint-parameterization-sweep.json
    tint-parameterization-focused-phase-2b.json
    tint-parameterization-hue-phase-2c.json
    tint-sync-resolution.json
    tint-wide-gamut-model.json
  macOS-27/
    ...the same files...
    semantic-usage-trees.json
  learnings/
  tools/
```

`capture.json` contains OS/build, architecture, display, capture time, and the capture-level transparency provenance available only on macOS 27. A canonical macOS 27 archive declares `processOverridePerObservation` with baseline `0.5`; each Static/Dynamic coordinate carries its own `glassAmount`. The key is completely absent on macOS 26. The directory location distinguishes staging from accepted evidence; there is no persisted status, profile, module registry, or compatibility protocol.

`static.json` contains 776 typed resolved-tree Snapshots on macOS 26 and 1,750 on macOS 27. The macOS 27 total is the original plan plus one sparse transparency union. Scalar research values, recursive topology, transparency models/fixtures, signatures, and the 56 midpoint Consumer samples are projections of those Snapshots rather than separately captured files. `dynamic.json` contains 104 lifecycle-aware runs on macOS 26 and 273 on macOS 27. Every new Dynamic sample retains one canonical native snapshot containing model, presentation, detailed layers, and attached animations.

Tint matrices and Semantic Usage are first-class Golden measurement documents because they measure different phenomena: color response and view semantics. Runtime notification/restamp checks remain release validation harnesses.

## The four workflows

All daily work goes through one entry point:

```sh
bun Golden/tools/golden.mjs <drift|capture|promote|catalog|tint-model|fixtures> ...
```

### 1. Check a system for drift

```sh
bun Golden/tools/golden.mjs drift \
  --app /path/to/LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --os macOS-27 \
  --output /private/tmp/macOS-27-drift.json
```

This captures 28 fixed sentinel coordinates with the production Snapshot walker and compares them directly with accepted Golden. A clean result means no drift was detected in that sampled set; it is not a replacement for Full capture.

### 2. Capture every declared case

```sh
bun Golden/tools/golden.mjs capture \
  --app /path/to/LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --output /private/tmp/macOS-27.staging
```

One top-level operation collects Static, Dynamic, Tint, and the per-major Semantic plan. On macOS 27, the app switches the process-local Glass amount at each declared coordinate while guarding against external changes. The app is sandboxed, so drivers return artifacts over stdout; long Tint sweeps may resume their own checkpoint. The final staging directory appears only after every document passes direct coverage and payload validation.

### 3. Review and promote that exact staging

Preview is the default:

```sh
bun Golden/tools/golden.mjs promote \
  --staging /private/tmp/macOS-27.staging \
  > /private/tmp/macOS-27-promotion.json
```

After reviewing the human-readable JSON comparison and learning outcomes, accept the same staging without recapture:

```sh
bun Golden/tools/golden.mjs promote \
  --staging /private/tmp/macOS-27.staging \
  --accept
```

Promotion revalidates the staging, copies it to an install transaction, and atomically creates or replaces `Golden/macOS-N`. The source staging remains reusable. New-major and same-major promotion are the same operation.

### 4. Generate the Consumer Catalog

```sh
bun Golden/tools/golden.mjs catalog --os macOS-27
bun Golden/tools/golden.mjs catalog --os macOS-27 --check
```

This is the sole writer of `LiquidGlassLab/GlassMaterial/Catalog/glass-macos-N.json`. It selects the 56 declared Consumer coordinates, projects each Snapshot to the narrow replay payload, proves the Main-On/Main-Off witness pairs, removes Tint matrices, and serializes deterministically. `--check` fails when the committed Catalog is stale.

The macOS 27 amount model and native regression fixtures are also deterministic projections:

```sh
bun Golden/tools/golden.mjs tint-model --os macOS-27 --check
bun Golden/tools/golden.mjs fixtures --check
```

Both commands read their coordinates directly from accepted `static.json`; there is no parallel source or migration fallback.

## Research commands

The four commands are the workflow surface, not a ban on diagnostics:

```sh
bun Golden/tools/verify.mjs
bun Golden/tools/verify.mjs --os macOS-27 --verbose
bun Golden/tools/compare.mjs Golden/macOS-26 Golden/macOS-27
bun test Golden/tools/*.test.mjs
```

`verify.mjs` admits the direct archive and runs every learning. A learning may pass, fail, or skip as unverifiable. A skip never looks green; reviewed exact exceptions remain in `verification-dispositions.json`.

`compare.mjs` compares complete archives by semantic observation identity. New macOS 27 archives compare the full transparency axis exactly. When one side is a legacy archive without `glassAmount`, comparison projects the new archive to the explicit `0.5` baseline and reports the additional coordinates and newly measured fields as coverage, without claiming the legacy value was known. Static numeric values use the documented `1e-6` comparison tolerance. The session-volatile `inputMaxHeadroom` is excluded from the equivalence verdict but its changed counts and examples are always reported separately; raw Golden retains it as display provenance, while the Consumer Catalog and strength controller leave it platform-owned. Topology is computed from the Snapshot rather than trusted from a stored signature.

## Design boundary

- Golden owns accepted measurements.
- The Swift plan is the only coordinate authority; JavaScript validates emitted shape and derives artifacts without copying the coordinate lists.
- Transparency capture, validation, model generation, and fixture generation are enabled only for exactly macOS 27.
- Catalog is a deterministic, packaged projection of accepted Golden.
- The runtime `GlassMaterialAtlasProvider` and its cache remain a product fallback, never an accepted-evidence producer.
- Display identity is provenance, not a promise of OS-only causality. Cross-version reports must be read with the recorded display context visible.
- Capture correctness is enforced: requested context, complete typed values, bounded strict settling, exact coordinate coverage, lifecycle/pairing, finalized staging, and atomic installation.
- The workflow does not authenticate a trusted developer against their own Git tree or defend local paths against an attacker.

The Swift Package processes only `LiquidGlassLab/GlassMaterial/Catalog`. Raw Golden evidence is repository-only and never ships to Consumers.
