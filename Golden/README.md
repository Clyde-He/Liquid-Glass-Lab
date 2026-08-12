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

`capture.json` contains only OS/build, architecture, display, and capture time. The directory location distinguishes staging from accepted evidence; there is no persisted status, profile, module registry, or compatibility protocol.

`static.json` contains 776 typed resolved-tree Snapshots. Scalar research values, recursive topology, signatures, and the 56 Consumer samples are projections of those Snapshots rather than separately captured files. `dynamic.json` retains the 104 lifecycle-aware transition runs. Tint remains compact color-conditioned matrix evidence. Semantic Usage remains a separate coordinate domain and is required on macOS 27 and later.

## The four workflows

All daily work goes through one entry point:

```sh
node Golden/tools/golden.mjs <drift|capture|promote|catalog> ...
```

### 1. Check a system for drift

```sh
node Golden/tools/golden.mjs drift \
  --app /path/to/LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --os macOS-27 \
  --output /private/tmp/macOS-27-drift.json
```

This captures 28 fixed sentinel coordinates with the production Snapshot walker and compares them directly with accepted Golden. A clean result means no drift was detected in that sampled set; it is not a replacement for Full capture.

### 2. Capture every declared case

```sh
node Golden/tools/golden.mjs capture \
  --app /path/to/LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --output /private/tmp/macOS-27.staging
```

One top-level operation collects Static, Dynamic, Tint, and the per-major Semantic plan. The app is sandboxed, so drivers return artifacts over stdout; long Tint sweeps may resume their own checkpoint. The final staging directory appears only after every document passes direct coverage and payload validation.

### 3. Review and promote that exact staging

Preview is the default:

```sh
node Golden/tools/golden.mjs promote \
  --staging /private/tmp/macOS-27.staging \
  > /private/tmp/macOS-27-promotion.json
```

After reviewing the human-readable JSON comparison and learning outcomes, accept the same staging without recapture:

```sh
node Golden/tools/golden.mjs promote \
  --staging /private/tmp/macOS-27.staging \
  --accept
```

Promotion revalidates the staging, copies it to an install transaction, and atomically creates or replaces `Golden/macOS-N`. The source staging remains reusable. New-major and same-major promotion are the same operation.

### 4. Generate the Consumer Catalog

```sh
node Golden/tools/golden.mjs catalog --os macOS-27
node Golden/tools/golden.mjs catalog --os macOS-27 --check
```

This is the sole writer of `LiquidGlassLab/GlassMaterial/Catalog/glass-macos-N.json`. It selects the 56 declared Consumer coordinates, projects each Snapshot to the narrow replay payload, proves the Main-On/Main-Off witness pairs, removes Tint matrices, and serializes deterministically. `--check` fails when the committed Catalog is stale.

## Research commands

The four commands are the workflow surface, not a ban on diagnostics:

```sh
node Golden/tools/verify.mjs
node Golden/tools/verify.mjs --os macOS-27 --verbose
node Golden/tools/compare.mjs Golden/macOS-26 Golden/macOS-27
node --test Golden/tools/*.test.mjs
```

`verify.mjs` admits the direct archive and runs every learning. A learning may pass, fail, or skip as unverifiable. A skip never looks green; reviewed exact exceptions remain in `verification-dispositions.json`.

`compare.mjs` compares complete archives by semantic observation identity. Static numeric values use the documented `1e-6` comparison tolerance and exclude volatile `inputMaxHeadroom`; topology is computed from the Snapshot rather than trusted from a stored signature.

## Design boundary

- Golden owns accepted measurements.
- Catalog is a deterministic, packaged projection of accepted Golden.
- The runtime `GlassMaterialAtlasProvider` and its cache remain a product fallback, never an accepted-evidence producer.
- Display identity is provenance, not a promise of OS-only causality. Cross-version reports must be read with the recorded display context visible.
- Capture correctness is enforced: requested context, complete typed values, bounded strict settling, exact coordinate coverage, lifecycle/pairing, finalized staging, and atomic installation.
- The workflow does not authenticate a trusted developer against their own Git tree or defend local paths against an attacker.

The Swift Package processes only `LiquidGlassLab/GlassMaterial/Catalog`. Raw Golden evidence is repository-only and never ships to Consumers.
