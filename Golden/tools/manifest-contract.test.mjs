import assert from "node:assert/strict";
import test from "node:test";
import { readManifest } from "./lib/golden.mjs";
import {
  MANIFEST_PROTOCOL_VERSION, normalizeManifest, profileModules,
  validateManifestV2,
} from "./lib/manifest.mjs";

test("committed manifests use protocol v2 and expose exact Full profiles", async () => {
  for (const os of ["macOS-26", "macOS-27"]) {
    const manifest = await readManifest(os);
    assert.equal(manifest.sourceProtocolVersion, MANIFEST_PROTOCOL_VERSION);
    assert.deepEqual(validateManifestV2(manifest), []);
    const full = profileModules(manifest);
    assert.ok(full.required.length >= 7);
    assert.ok(full.required.every(Boolean));
    assert.ok(full.carriedForward.every(Boolean));
  }
});

test("v1 manifests dual-read into stable module IDs", async () => {
  const manifest = await normalizeManifest({
    schemaVersion: 1,
    platform: { product: "macOS", version: "26.0", build: "test" },
    fixtures: [{
      id: "tint-sync-resolution", file: "tint.json", sha256: "abc",
      formatVersion: 1, role: "canonical",
    }],
  }, { osDirectory: "missing", goldenDirectory: "/missing" });
  assert.equal(manifest.sourceProtocolVersion, 1);
  assert.equal(manifest.modules[0].id, "tint.sync-resolution");
  assert.equal(manifest.modules[0].file, "tint.json");
});

test("v2 validation rejects profile references to unknown modules", () => {
  const problems = validateManifestV2({
    protocolVersion: 2,
    modules: [],
    profiles: { full: {
      required: ["missing"], optional: [], unsupported: [], carriedForward: [],
    } },
  });
  assert.ok(problems.some((problem) => problem.includes("unknown module missing")));
});
