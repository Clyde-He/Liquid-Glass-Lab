# Releasing AdjustableGlass

`AdjustableGlass` uses Semantic Versioning tags. SwiftPM resolves versions from Git tags; `Package.swift` has no version field.

## Prepare the release

1. Update `CHANGELOG.md`, moving completed entries from `Unreleased` into a dated version section.
2. Verify every accepted Golden and all cross-version learnings:

   ```sh
   node Golden/tools/verify.mjs
   ```

3. Require the committed Catalog for each certified major to be the deterministic Golden projection:

   ```sh
   node Golden/tools/golden.mjs catalog --os macOS-26 --check
   node Golden/tools/golden.mjs catalog --os macOS-27 --check
   ```

4. Run the Node and Swift suites. The Swift suite automatically checks the Golden-backed Tint model for every supported macOS major:

   ```sh
   node --test Golden/tools/*.test.mjs
   swift test
   ```

5. Confirm `swift package dump-package` exposes `Catalog` as the only processed product resource. Golden must remain repository-only.
6. Build the independent consumer:

   ```sh
   xcodebuild \
     -project LiquidGlassLab.xcodeproj \
     -target GlassHUDConsumerDemo \
     build
   ```

7. Exercise Regular/Clear, Light/Dark, active/inactive, Tint, the supported geometry range, and both Outer Shadow policies in the Consumer Demo. Confirm the bundled Provider serves at least one value known to come from the current generated Catalog.
8. Inspect the final diff and ensure the repository is clean after committing. Any later change requires rerunning the relevant checks.
9. Merge the release-preparation pull request and fast-forward local `main` to `origin/main`.

## Publish the release

Create an annotated tag from the verified `main` commit:

```sh
git tag -a 0.1.0 -m 'AdjustableGlass 0.1.0'
git push origin 0.1.0
```

Create a GitHub Release from that tag using the matching `CHANGELOG.md` section. Never move or reuse a published tag; issue a new patch release for corrections.

## Version policy before 1.0

- Patch: fixes and Catalog corrections that preserve the supported API.
- Minor: supported API additions, new certified macOS majors, or explicitly documented breaking changes.
- Major: the public API and private-runtime compatibility policy are stable enough for a `1.0.0` contract.
