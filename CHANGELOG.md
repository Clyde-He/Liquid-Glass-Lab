# Changelog

All notable changes to `AdjustableGlass` are documented in this file.

The project follows [Semantic Versioning](https://semver.org/). While the
package remains below `1.0.0`, minor releases may refine the supported API;
those changes will be called out explicitly here.

## [Unreleased]

## [0.2.1] - 2026-07-31

### Fixed

- Tint color and opacity updates now share one display-cadence presentation
  path, preventing streamed opacity changes from racing AppKit's native Recipe
  restamp and visibly flickering the frozen material.
- Wider-gamut Tint resolution preserves its legacy-capture fallback, suspends
  its display link while resolution is gated, and audits the frozen material
  after the pre-commit reassertion instead of reporting transient failures.

## [0.2.0] - 2026-07-31

### Added

- Added `referenceView` as a consumer-owned AppKit insertion point for
  invisible material probes in view-controller-managed windows.

### Changed

- Runtime calibration and wider-gamut Tint now require an explicit
  `referenceView` when the reference window has a `contentViewController`;
  controller-owned content roots are no longer used as implicit probe hosts.

### Fixed

- Material probes no longer attach directly to `NSHostingController.view`,
  avoiding unsupported SwiftUI view-hierarchy mutations and AppKit warnings.
- A `referenceView` assigned before it joins its reference window remains
  available for runtime calibration and wider-gamut Tint once attached.

## [0.1.0] - 2026-07-31

### Added

- `AdjustableGlassEffectView`, an `NSGlassEffectView` subclass with continuous
  `effectAmount` and deterministic active/inactive material state.
- Supported Regular/Clear styles, system or forced appearance, verified Tint,
  replaceable reference windows, status reporting, and batched configuration.
- `hasOuterShadow` and size-dependent `requiredWindowInset` integration for
  transparent nonactivating HUD panels.
- Bundled, verified macOS 26 and macOS 27 material catalogs with runtime
  calibration as the fallback for an uncertified macOS major.
- A standalone Consumer Demo covering the supported product API, geometry,
  window placement, rounded hit testing, and panel shadow behavior.
- Package tests covering catalog admission, configuration transactions,
  platform inset policy, Tint synthesis, and recovery behavior.

### Compatibility

- The package can be linked from a macOS 15 deployment target so consumers can
  retain an older-system fallback. `AdjustableGlassEffectView` itself is
  available on macOS 26 and later.
- The implementation relies on private AppKit details and is intended for
  Direct Distribution, not the Mac App Store.

[Unreleased]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.2.1...HEAD
[0.2.1]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/Clyde-He/Liquid-Glass-Lab/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Clyde-He/Liquid-Glass-Lab/releases/tag/0.1.0
