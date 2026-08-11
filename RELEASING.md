# Releasing AdjustableGlass

`AdjustableGlass` uses Semantic Versioning tags. The Swift Package manifest does not contain a version number; SwiftPM resolves versions from Git tags.

## Prepare the release

1. Update `CHANGELOG.md`, moving completed entries from `Unreleased` into a dated version section.
2. Confirm every supported macOS major has a bundled catalog and has completed its targeted on-device visual acceptance.
3. Review the supported surface in `LiquidGlassLab/GlassMaterial/README.md`. Experimental SPI is not part of the stable product contract.
4. Run the package tests:

   ```sh
   swift test
   ```

5. Build the independent consumer:

   ```sh
   xcodebuild \
     -project LiquidGlassLab.xcodeproj \
     -target GlassHUDConsumerDemo \
     build
   ```

6. Exercise Regular/Clear, Light/Dark, active/inactive, Tint, the supported geometry range, and both Outer Shadow policies in the Consumer Demo.
7. Merge the release-preparation pull request and fast-forward local `main` to `origin/main`.

## Publish the release

Create an annotated tag from the verified `main` commit:

```sh
git tag -a 0.1.0 -m 'AdjustableGlass 0.1.0'
git push origin 0.1.0
```

Create a GitHub Release from that tag and use the matching `CHANGELOG.md` section as its notes. Do not move or reuse a published version tag; release a new patch version for corrections.

## Version policy before 1.0

- Patch: fixes and catalog corrections that preserve the supported API.
- Minor: supported API additions, new certified macOS majors, or an explicitly documented breaking change.
- Major: the long-term public API and private-runtime compatibility policy are stable enough for a `1.0.0` contract.
