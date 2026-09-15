# Changelog

All notable changes to `AdjustableGlass` are documented in this file.

The project follows [Semantic Versioning](https://semver.org/). While the package remains below `1.0.0`, minor releases may refine the supported API; those changes will be called out explicitly here.

## [Unreleased]

### Added

- Added macOS 27-only `tintAmount` with system following by default, manual `0...1` control, and `resolvedTintAmount` readback, independently of `effectAmount` and colored Tint.
- Added a measured three-anchor material model, a Golden-derived native-coordinate regression fixture, and a live system-following/override verification harness.
- Added a macOS 27-only Glass Amount slider and System checkbox to Consumer Demo.
- Added macOS 27-only native Glass Amount controls to Lab, live Backdrop Scale editing and audit readouts, and sampling records for Static, Dynamic and Semantic captures.
- Expanded the canonical macOS 27 Golden plan to 1,750 Static observations and 273 Dynamic runs across a sparse transparency axis; macOS 26 remains 776/104 and contains no transparency coordinate.
- Added per-observation Glass amount provenance and lossless Dynamic model/presentation/animation snapshots to the canonical Golden acquisition path.
- Generated transparency models and native regression fixtures directly from accepted Golden coordinates.

### Fixed

- Match macOS 27’s native backdrop sampling selection from the requested material endpoint, including opaque Regular’s `0.25`/`0.125` buckets and its constant sampling through Materialize. Include scale in frozen drift detection, Golden capture and research projections so manual transparency remains independent of system changes.
- Resolve macOS 27 native geometry caps, bleed sampling gates and logarithmic shadow output bounds between atlas coordinates.
- Keep Clear inactive baseline blur at tint amount zero; only the active Clear recipe gates that blur off.
- Preserve manually selected Glass tint amount when AppKit updates its native material after a system transparency notification, including a follow-up restamp for later native writes.
- Explicitly apply the requested corner radius after rebuilding a glass for canonical static capture, preserving the strict capture-context check.

## [0.3.4] - 2026-08-20

### Fixed

- Stabilized Clear Main On Tint updates by keeping streamed nonnil colors out of AppKit's native Tint setter while preserving the native fallback handoff.
- Kept HUD Tint presentation responsive during Color Panel tracking with one display-cadence beat shared by input and display-link delivery, while commit resolution remains deferred outside configuration updates.

## [0.3.3] - 2026-08-17

### Fixed

- Refreshed the macOS 27 Golden archive and bundled Catalog from a complete capture on build `26A5416b`.
- Kept display-derived `inputMaxHeadroom` in raw Golden diagnostics while leaving it platform-owned in Catalog replay, preventing one display's finite HDR headroom from being stamped onto another display.

## [0.3.2] - 2026-08-13

### Fixed

- Contained HUDs now preserve the native backdrop sampling margin after disabling only the outer shadow, replacing the previous 0pt/0.5pt sampling override on macOS 26/27. They also reserve a uniform 1pt window safety inset after controlled Dock dragging showed that a 0pt room flashes at the backing-surface edge on macOS 26.

## [0.3.1] - 2026-08-13

### Fixed

- Refreshed the bundled macOS 26 and macOS 27 Regular/Clear material Catalogs from accepted captures on builds `25G82` and `26A5406e`, correcting the resolved values served to Consumer applications without changing the public API.
- Catalogs are now deterministic projections of the same typed Golden Snapshots used for release verification, eliminating the independent capture path that could let packaged values diverge from accepted evidence.

## [0.3.0] - 2026-08-03

### Added

- Added `setReferenceHost(window:view:)` as the preferred atomic way to replace or detach the calibration host without exposing an intermediate window/view pair.

### Changed

- Tint resolution, resolved-material planning, and live-tree installation now have separate internal owners, with side-effect-free planning and generation-bound asynchronous work.

### Fixed

- Closing, replacing, or reopening a reference window now preserves an already verified material and cached Tint while unresolved work waits for and resumes on a participating host.
- Redundant applies now validate the live frozen tree, and stale calibration, Tint warm-up, legacy-capture, and installation-retry work can no longer mutate or clear a replacement generation.
- macOS 27 contained glass preserves its required half-point internal sampling margin while exposing the documented one-point consumer window inset; muted glass continues to use the platform safety inset.
- Clear glass now settles pending native Recipe layout before the coalesced Tint presentation writer, preventing streamed NSColorPanel updates from exposing a transient native Main-Off frame.
- The Consumer Demo remains usable when its reference window closes and avoids unrelated panel geometry work during material-only updates.

## [0.2.2] - 2026-08-02

### Fixed

- Display P3 Tint now uses the certified closed-form matrix synthesis on both macOS 26 and macOS 27, preserving the original extended-sRGB components without requiring a reference window, cache warm-up, or sRGB clamping.
- Complete matrix sets for verified Tints beyond the certified Display P3 domain are now retained in a bounded, exact-RGB, macOS-major-scoped runtime cache, allowing HUD-only apps to restore them on cold launch without an ordinary main or key window.

## [0.2.1] - 2026-07-31

### Fixed

- Tint color and opacity updates now share one display-cadence presentation path, preventing streamed opacity changes from racing AppKit's native Recipe restamp and visibly flickering the frozen material.
- Wider-gamut Tint resolution preserves its legacy-capture fallback, suspends its display link while resolution is gated, and audits the frozen material after the pre-commit reassertion instead of reporting transient failures.

## [0.2.0] - 2026-07-31

### Added

- Added `referenceView` as a consumer-owned AppKit insertion point for invisible material probes in view-controller-managed windows.

### Changed

- Runtime calibration and wider-gamut Tint now require an explicit `referenceView` when the reference window has a `contentViewController`; controller-owned content roots are no longer used as implicit probe hosts.

### Fixed

- Material probes no longer attach directly to `NSHostingController.view`, avoiding unsupported SwiftUI view-hierarchy mutations and AppKit warnings.
- A `referenceView` assigned before it joins its reference window remains available for runtime calibration and wider-gamut Tint once attached.

## [0.1.0] - 2026-07-31

### Added

- `AdjustableGlassEffectView`, an `NSGlassEffectView` subclass with continuous `effectAmount` and deterministic active/inactive material state.
- Supported Regular/Clear styles, system or forced appearance, verified Tint, replaceable reference windows, status reporting, and batched configuration.
- `hasOuterShadow` and size-dependent `requiredWindowInset` integration for transparent nonactivating HUD panels.
- Bundled, verified macOS 26 and macOS 27 material catalogs with runtime calibration as the fallback for an uncertified macOS major.
- A standalone Consumer Demo covering the supported product API, geometry, window placement, rounded hit testing, and panel shadow behavior.
- Package tests covering catalog admission, configuration transactions, platform inset policy, Tint synthesis, and recovery behavior.

### Compatibility

- The package can be linked from a macOS 15 deployment target so consumers can retain an older-system fallback. `AdjustableGlassEffectView` itself is available on macOS 26 and later.
- The implementation relies on private AppKit details and is intended for Direct Distribution, not the Mac App Store.

[Unreleased]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.3.4...HEAD
[0.3.4]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.3.3...0.3.4
[0.3.3]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.3.2...0.3.3
[0.3.2]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.3.1...0.3.2
[0.3.1]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.2.2...0.3.0
[0.2.2]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Clyde-He/Liquid-Glass-Lab/releases/tag/0.1.0
