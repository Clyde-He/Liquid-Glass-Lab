# macOS 27 release and Glass transparency

## Result — 2026-09-15

The default macOS 27.0 release material does not require a Catalog value update in the measured sentinel domain. Following the new system transparency preference does require a separate material parameter: it is not the existing Materialize `effectAmount`.

The comprehensive acquisition is now the accepted macOS 27 Golden. The packaged Catalog payload remains unchanged; only its build/display provenance moved to the formal release capture. The accepted transparency model and native regression fixture are deterministic projections of that same archive.

## Release drift

The initial release-drift comparison ran on macOS 27.0 build `26A428`, on Built-in Retina Display @2x, against the previous build `26A5416b` capture from Studio Display XDR @2x. Display context differed, so that comparison could not isolate OS-only causality. The `26A428` Built-in Retina capture is now the accepted baseline.

The canonical 28-sentinel drift capture completed after fixing a capture ownership bug: `isCapturingRecipeMatrix` suppresses ordinary host updates, so a freshly rebuilt glass retained AppKit's default 8pt corner radius. The static driver now explicitly sets the requested corner radius before applying its recipe. The strict 16pt context assertion remains intact.

All 28 raw differences are the same internal Swift type-name hash change in the content hosting layer: `$19fa85de48RootView_` became `$195593df48RootView_`. No other snapshot field or topology changed at the comparator's `1e-6` tolerance. The strict comparator still reports drift; its comparison policy has not been weakened to hide the name change. All 24 Consumer sentinel projections are unchanged; 25 of the 28 total sentinels are projectable and all 25 projections match. `golden.mjs catalog --os macOS-27 --check` passes.

## Reading the setting

The release AppKit binary exports private `NSGlassEffectView.Legibility.systemLegibility()`, with `.tintAmount(Float)`, `.standard`, and `.increased` cases. A standalone arm64 diagnostic verified the runtime value layout (5-byte size, 8-byte stride) before invoking the indirect-return getter. Default, `0.25`, and `1` reads returned `0.5`, `0.25`, and `1`, respectively. The default getter result was the continuous `.tintAmount` case, not a missing-value zero.

`NSGlassTintAmount` can be overridden in the current process through a Foundation launch argument. All experiments used that mechanism; they did not write global preferences. The default 28-snapshot document is exactly equal to the explicit `0.5` document. A raw `defaults read -g` can omit this key even though AppKit resolves a value, so key absence must not be interpreted as `0`.

Binary inspection also found `NSGlassDiffusionSetting`, AppKit's `NSGlassEffectDiffusionDidChangeNotification`, `previewSystemLegibility` / `commitSystemLegibility`, and AppearancePreferencesFramework's `GlassStyleModel.previewTintAmount` / `commitTintAmount`. SwiftUICore exports `EnvironmentValues.glassDiffusion` and `_Glass.Diffusion.amount(Float)`. These are private implementation details, absent from the checked public macOS 27 SDK interfaces. The notification's delivery from an actual Settings interaction and legacy/accessibility precedence have not yet been runtime-certified.

## Interpolation measurements

The same 28 contexts were captured at `t = 0, 0.25, 0.5, 0.75, 1`, plus an uncontrolled-default capture: 168 typed snapshots. Product coverage is Light/Dark × Regular/Clear × main/non-main × short side 48/200/320pt, with the four existing research sentinels included. Tint color is nil and the backdrop is controlled Light. Here `t` is the system's tint amount: increasing it generally makes the material less transparent.

Continuous channels fit interpolation through three captured anchors (`0`, `0.5`, `1`) at the tested quarter points, with maximum absolute residual `1.49e-8`. This is evidence for a piecewise-linear model in the sampled domain, not proof at every real-valued input or every context. Some channels are discrete gates and must be excluded from that interpolation.

Examples at 480×200:

| Context / channel | t=0 | t=0.25 | t=0.5 | t=0.75 | t=1 |
|---|---:|---:|---:|---:|---:|
| Regular Light, blur-fill lighten opacity | .675 | .7875 | .9 | .9 | .9 |
| Regular, blur-fill normal opacity | 0 | .25 | .5 | .75 | 1 |
| Regular Light, face-fill alpha | 0 | .1 | .2 | .35 | .5 |
| Regular Dark, face-fill RGB component | .125 | .0625 | 0 | .0625 | .125 |
| Clear main, blur radius | 0 | .375 | .75 | .75 | .75 |
| Clear, blur-fill normal opacity | 0 | 0 | 0 | .5 | 1 |
| Clear, blur-fill blur radius | 0 | 0 | 0 | 8 | 8 |
| Clear main, marginWidth | .5 | .5 | .5 | 16 | 16 |

Clear main's blur opacities also switch from zero at `t=0` to `[1, .5, .5, 1]` at the positive sampled values. Clear non-main does not change between `0` and `0.5`, but does change in the upper half. Regular Dark's RGB values must be retained even at zero alpha; changing only alpha would lose the system's color path.

A separate untouched, public `NSGlassEffectView` probe at Light/Clear, 480×200, in a genuinely main **and key** titled window sampled `0`, `0.0001`, `0.4999`, `0.5`, `0.5001`, and `1`. It confirmed behavior consistent with blur-opacity gates at `t > 0` and blur-fill radius at `t > 0.5`. This focused probe is a different participation/host context from the Panel main-only sentinels; it is supporting boundary evidence, not an extension of their exact coverage. It did not measure marginWidth near the threshold.

## Product implementation

`AdjustableGlassEffectView.tintAmount: CGFloat?` now exposes this independent parameter. `nil` (the default) follows the system; `0...1` pins a manual value. `resolvedTintAmount` reports the resolved request, and `onResolvedTintAmountChange` reports effective-value changes from the system or manual selection. Configuration batches coalesce this callback to the final value, while system notifications in manual mode repair the installed material without reporting a value change. All three APIs are available only from macOS 27; exact-major capability checking still rejects future unmeasured systems. Values are clamped; NaN resolves to the measured default `0.5`. Unsupported macOS majors retain their existing calibrated behavior without applying this model.

The bundled `glass-tint-amount-macos-27.json` holds three native anchors for all 56 Consumer coordinates: Light/Dark × Regular/Clear × main/non-main × short side 48/64/96/128/160/200/320pt. Size interpolation retains the existing atlas policy outside the macOS 27 native geometry corrections below, with nearest-endpoint behavior outside the sampled size range. The canonical plan includes held-out quarter points, including `.25` at 72/104/112/120pt, within the same Static coordinate union. The midpoint preserves all 56 bundled Catalog numeric vectors and margins.

The writer resolves the 11 slider-dependent numeric inputs, face-fill RGBA and Clear margin, corrects native geometry caps/gates and output range, and selects native sampling before applying existing Materialize curves. Discrete Clear gates are preserved. The immutable base atlas and RGB matrix cache stay independent of the slider; the resolved amount participates in material installation identity, so changing it reinstalls the appropriate material without recapturing an atlas or creating one cache entry per slider position. Existing `hasOuterShadow = false` policy still requests 1pt window room while retaining native sampling margin.

A separate 24-case native probe at 480×200 crossed one colored Tint `(0.173, 0.617, 0.842, 0.88)` versus nil with Light/Dark, Regular/Clear and amounts `0`, `0.5`, `1`, in a genuinely main and key window. Its color matrices were invariant across amounts, and the background shader at each amount was identical with and without Tint. This supports independent matrix composition in the tested domain, not an exhaustive proof over every RGB or host.

The version-gated settings adapter reads `NSGlassTintAmount` through `UserDefaults.standard` (including AppKit's registration defaults), responds to AppKit's diffusion notification and defaults changes, and rechecks on application/window participation changes. An unreadable value retains the last readable value, initially the measured `0.5`; key absence never becomes zero. No private Swift ABI getter or system preference write is included in the product.

Validation on build `26A428` covered every product cell at five amounts with colored Tint, `effectAmount = 0.5`, 96/200pt resizing and complete frozen readback, followed by process-local simulated system notifications, manual override and returning to system following at full effect. Additional rows changed the process-local setting through `0 → 1 → 0`, asserted that an untouched native witness actually followed it, and checked the manually configured product after 16/80/400ms waits. The pre-fix run lost complete frozen readback in two early samples; the notification handler now reasserts the selected material immediately and again on the next main-queue turn, including in manual mode. A separate regression test corrupts the live shader and margin and requires notification delivery to restore them synchronously, without waiting for the periodic guard. No property animations were observed in the additional native-change samples, so this fix does not remove arbitrary animations. The Demo was also opened and its System/manual control checked. These integration checks establish installed-state consistency; they are not independent native animation-curve measurements.

The accepted Golden now measures 72 System Default Materialize/Dissolve runs across Glass amounts `0`, `0.5`, and `1`. Its macOS 27-only learning verifies the nine-sample lifecycle, front-loaded progress envelope, consistency across amounts, approximate insertion/removal reversibility, and the absence of an exposed attached `CAAnimation` duration. This establishes the measured SwiftUI System Default envelope at those coordinates; it does not identify the private curve by name or turn scheduler-dependent samples into exact control points.

Still unverified: delivery and preview/commit timing from an actual Settings drag, whether that Settings interaction uses the same temporal envelope, other backdrops, accessibility precedence, and visual acceptance of intermediate materials. The API replays the measured material interpolation path; it does not promise identical temporal easing to Settings.

## Backdrop sampling correction

The first notification repair was incomplete. Clyde reproduced a persistent blur change with Regular, no colored Tint, manual amount `0`, and the system slider at its opaque end. Expanded inspection of `CA_attributes` on the model and presentation layers found `CABackdropLayer.scale` changing from `0.5` to `0.125` while the entire canonical Golden snapshot remained identical. Golden previously recorded margin but omitted this sampling ratio, so the earlier claim of complete frozen readback did not cover it. The canonical walker now captures `scale`, and both Swift and JavaScript research projections preserve layer properties; scalar projections expose `backdropScale`. A regression verifies that a scale-only change changes the research value signature. Older accepted archives are preserved as historical evidence and are not retroactively given invented scale values.

A 616-row native probe crossed seven sizes (48/64/96/120/160/200/320pt), actual main/non-main windows, Light/Dark, Regular/Clear and 11 amounts. Regular uses `0.5`, `0.25`, `0.125`; its switching thresholds depend on size, appearance and participation. Clear stayed at `0.5` in this probe. These are sampling-quality changes in addition to the slider-dependent shader inputs.

The fixed `0.5` workaround has been replaced with the native Regular recipe's `DesignLibrary.GlassMaterialProvider.BackdropScalePerceptualEstimator`. Local symbol/disassembly inspection and live input traces establish this rule, with `Float` operations and the native constant bit pattern preserved at bucket boundaries:

- `r = inputBlurRadius × inputBlurOpacity0`; `b = inputBlurFillBlurRadius`.
- `f = inputFaceColorMatrixFillColor.alpha`; `o = inputBlurFillNormalOpacity`, with opacities clamped to `0...1`.
- For each ascending bucket `s ∈ [0.125, 0.25, 0.5]`, compute `L(r,s) = exp(k × r × r × s × s × 0.25)`, where `k` is `Float(bitPattern: 0xc11de9e5)` (approximately `−π²`).
- Select the first bucket for which `(1−f) × [o × L(b,s) + (1−o) × L(r,s)] ≤ 0.05`, falling back to `0.5` if none passes.
- Clear's native recipe does not invoke this estimator and uses fixed `0.5`.

The same estimator matches all 616 independently captured native grid observations, including size/appearance/participation-dependent switches. This is not interpolation between sampled scale values: the discrete native selection is computed from the requested endpoint, so intermediate sizes and amounts can cross the appropriate threshold. No private Swift ABI call is used by the product.

Native SwiftUI insertion and removal at Regular/Light/Main-On, 480×200pt, corner radius 16 and `t=1` produced 52 presentation samples (46 with an attached backdrop). Scale remained `0.125` through the full observed face-opacity range `0...1`; repeated native estimator calls all received the unchanged endpoint `(r=4, b=8, f=0.5, o=1, epsilon=0.05)`. The product therefore computes sampling **before** Materialize interpolation, rather than choosing a different bucket for each animated shader frame. macOS 26 and raw Lab/calibration views retain their existing sampling behavior.

For the reported Regular/no-Tint/manual-zero case at 320×120pt and corner radius 24, 36 observations crossed Light/Dark, nine system values (`0`, `.25`, `.4999`, `.5`, `.5001`, `.6`, `.75`, `.9`, `1`) and two delays. With the native estimator, the complete canonical snapshots and all inspected model/presentation layer scalars stayed identical across amounts; `scale` stayed `0.5`. A unit regression corrupts only `scale` while leaving shader inputs intact and requires drift detection plus notification repair. These checks establish the inspected state; on-device visual acceptance remains Clyde's final check.

The discovery run's final verification had **1496/1496** full native recipe comparisons pass at `1e-5`, **36/36** focused manual-zero model/presentation observations stay invariant across system changes, and **53/53** integration checks pass. The full comparison used matching native shadow policy and did not exclude material input differences. Forty-eight grid rows required one or two extra 16ms readiness checks; this is recorded rather than presented as zero settling latency. Current regression status is reported by the repository's live checks rather than frozen into this research note.

## Native geometry corrections

Full-material comparison exposed older linear-interpolation errors at sizes between atlas coordinates. The product now resolves these macOS 27 endpoints with the measured native caps/gates instead of drawing a line across each knee:

| Parameter | Native rule for short side `S` in the calibrated domain |
|---|---|
| Regular inner refraction amount / height | `−min(60, 0.5S)` / `min(20, 0.25S)` |
| Regular active outer refraction height | `max(16, 0.2S)` |
| Regular active bleed blur / sampling margin | Blur `0` at `S≤64`, otherwise `0.35S`; margin `max(16, blur)` |
| Regular Dark max-luma channels | Interpolate each transparency anchor's 64pt/128pt values over `S=64...104`, then hold the endpoint |
| Clear inner refraction / shadow amount | `−min(60, 0.65S)` / `min(75, 0.625S)` |
| Clear inactive blur radius | Interpolate each transparency anchor's 48pt/128pt values over `S=48...120`, then hold the endpoint |

Regular active output maximum is `max(8.890357668551713, shadowRadius × E(shadowOpacity))`. The first term is the fixed native outer-pass bound in the captured recipe. Local inspection of DesignLibrary's range helper at unslid `0x23f51d550`, shadow helper `0x23f51f0b8`, and extent helper `0x23f502ac8` established the native extent calculation. With `a` converted from `Float` to `Double`, `E(a)` is `0` at `a≤0.005`, `max(0, 1.65 + 0.3 ln(2(a−0.005)))` below `0.505`, and `1.65 + 0.05(min(a,1)−0.505)/0.495` above that threshold. It reproduces all captured native output bounds exactly when supplied with native radius/opacity inputs.

The canonical native grid covers 17 sizes, 8 cells and targeted amounts, with actual Main/Key state recorded, Key off, and product `hasOuterShadow=true` to match the unmodified native reference. Default product outer-shadow suppression is an intentional separate API policy and must not be mistaken for a native mismatch. One generated regression fixture projects every product-reachable non-midpoint row from accepted Golden and compares the whole replay payload, including shader inputs, colors, points, grades, rims, output bounds and backdrop scale. The capture waits for settled readback with a bounded deadline; the user's manual-zero scenario retains fixed 16ms/400ms observations in the live integration harness.

Full comparison also exposed an incorrect gate in the initial transparency implementation: only Clear **active** turns off blur-gradient opacities at `t=0`. Clear inactive retains its baseline blur throughout `t=0...0.5`. The gate is now participation-specific, and the Golden-derived fixture includes all four blur-opacity inputs so this endpoint cannot silently regress.

## Evidence and reproduction

Build `LiquidGlassLab`, then capture the complete canonical archive through the one Golden entry point:

```sh
bun Golden/tools/golden.mjs capture \
  --app /path/to/LiquidGlassLab.app/Contents/MacOS/LiquidGlassLab \
  --output /private/tmp/macOS-27.staging
```

On macOS 27 the Swift plan captures 1,750 Static observations and 273 Dynamic runs. `glassAmount` is switched process-locally per observation; the 56 Catalog cells remain the explicit `0.5` subset. The plan includes all model, geometry, scale, quarter, Tint-interaction, boundary, Linear, and System Default coordinates in one union. There is no separate transparency Study capture.

After the staging is reviewed and accepted, the model and fixtures are regenerated from those canonical rows:

```sh
bun Golden/tools/golden.mjs tint-model --os macOS-27
bun Golden/tools/golden.mjs fixtures
bun Golden/tools/golden.mjs tint-model --os macOS-27 --check
bun Golden/tools/golden.mjs fixtures --check
```

Run live product checks with `--verify-glass-tint-amount @temporary/tint-integration.json --artifact-stdout`.

The live product harness remains release validation for system notifications, manual override, repair, and readback. It is intentionally not substituted for the reusable Static/Dynamic measurements.

Apple describes automatic adoption of the transparency slider for native Liquid Glass in [Platforms State of the Union, WWDC26](https://developer.apple.com/videos/play/wwdc2026/102/). That public behavior does not certify a custom frozen-atlas renderer.

## Lab controls and capture compatibility

On macOS 27, Recipe and Semantic General pages expose Glass Amount with System/manual selection and an effective-value readout. The controls are absent on macOS 26 and on future unmeasured majors. The Backdrop owner-layer inspector exposes sampling Scale alongside render Margin, including live capability detection and the existing override mechanism. Recursive text audits print layer properties, including Scale and Margin. Semantic model/presentation snapshots and standard Golden Dynamic samples also retain typed backdrop sampling records.

On macOS 27, canonical Golden records capture-level `processOverridePerObservation` provenance with baseline `0.5`, while every Static and Dynamic row carries its declared amount. The exporter pins and validates its process-local value at each coordinate, isolating the measurement from external Settings changes, and restores the pre-capture Lab selection on success or failure. macOS 26 coordinates and provenance contain no `glassAmount` key. The model/fixture generators accept only `macOS-27`. Legacy evidence remains unchanged; comparison projects a new archive to its explicit midpoint and reports additional fields/coordinates as coverage rather than backfilling them.

The accepted formal-release archive contains exactly 1,750 unique Static observations, 56 Consumer anchors, 28 drift sentinels, and 273 Dynamic runs. With the macOS 27 System Default timing learning enabled, verification reports 55 passed learnings, no failures, and three reviewed skips; the generated native fixture validates 912 non-midpoint transparency observations.
