# Golden manifest protocol

`manifest.json` is the sole registration authority for an OS archive. Protocol v2 keeps the flat on-disk layout while assigning every payload a stable module ID and an explicit lifecycle state.

## Module contract

Every entry in `modules` records:

- `id`: stable semantic identity, independent of its file path;
- `file`: payload path relative to the OS directory;
- `payloadSchemaVersion` and `planVersion`: data shape and capture-plan revisions;
- `platform`: exact product, version, build, and architecture provenance;
- `capturedAt` and `capture`: timestamp plus environment/session provenance, with explicit `null` when historical evidence did not record a value;
- `provenance`: direct, legacy, control, derived, or external origin details;
- `coverageClaims`: claims the payload keeps re-derivable;
- `integrity`: authoritative SHA-256 and byte count;
- `role`: canonical, control, or derived evidence role;
- `profileStatus`: `required`, `optional`, `unsupported`, `carried-forward`, or `excluded`.

`unified/meta.json` may repeat section statistics and capture metadata for payload-local diagnostics. Registration, role, platform, and checksums come from the root manifest.

## Full profile

`profiles.full` enumerates exact module IDs in four mutually exclusive lists:

- `required`: must be present and valid for a Full capture to be promotable;
- `optional`: captured when available without invalidating an otherwise complete profile; the ID may be listed before that OS has a payload;
- `unsupported`: a known module that this OS cannot produce;
- `carriedForward`: externally produced evidence whose provenance and checksum are retained but which the current Lab cannot recapture.

Modules marked `excluded` are registered evidence but are never implied by Full. This is how legacy or research fixtures remain auditable without making the canonical capture profile ambiguous.

## Compatibility

`tools/lib/manifest.mjs` dual-reads both protocols. A v1 manifest is normalized into stable module IDs at read time. A v2 manifest is validated and exposed through both its native module view and a temporary legacy fixture view so consumers can migrate independently. `tools/upgrade-manifest-v2.mjs` performs the deterministic v1-to-v2 registration upgrade and is safe to rerun.
