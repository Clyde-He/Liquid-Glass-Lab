import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { readManifest } from "./lib/golden.mjs";
import {
  MANIFEST_PROTOCOL_VERSION, normalizeManifest, profileModules,
  validateManifestV2,
} from "./lib/manifest.mjs";

test("committed manifests use protocol v2 and expose exact Full profiles", async () => {
  const expected = {
    "macOS-26": {
      required: ["core.static-scalar", "core.static-tree", "core.dynamic", "tint.parameterization.sweep", "tint.parameterization.focused-2b", "tint.parameterization.hue-2c", "tint.sync-resolution", "tint.wide-gamut"],
      optional: ["semantic.usage-trees"], unsupported: [], carriedForward: [],
    },
    "macOS-27": {
      required: ["core.static-scalar", "core.static-tree", "core.dynamic", "tint.parameterization.sweep", "tint.parameterization.focused-2b", "tint.parameterization.hue-2c", "tint.sync-resolution", "tint.wide-gamut", "semantic.usage-trees"],
      optional: [], unsupported: [], carriedForward: ["external.window-context"],
    },
  };
  for (const os of Object.keys(expected)) {
    const manifest = await readManifest(os);
    assert.equal(manifest.sourceProtocolVersion, MANIFEST_PROTOCOL_VERSION);
    assert.deepEqual(validateManifestV2(manifest), []);
    const full = profileModules(manifest);
    assert.deepEqual(manifest.profiles.full.required, expected[os].required);
    assert.deepEqual(manifest.profiles.full.optional, expected[os].optional);
    assert.deepEqual(manifest.profiles.full.unsupported, expected[os].unsupported);
    assert.deepEqual(manifest.profiles.full.carriedForward, expected[os].carriedForward);
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
  const optionalTypo = validateManifestV2({
    protocolVersion: 2, modules: [],
    profiles: { full: {
      required: [], optional: ["semantic.usage-treez"], unsupported: [], carriedForward: [],
    } },
  });
  assert.ok(optionalTypo.some((problem) => problem.includes("unknown module semantic.usage-treez")));
});

test("v2 validation requires the documented module contract", () => {
  const problems = validateManifestV2({ protocolVersion: 2, modules: [] });
  assert.ok(problems.includes("profiles.full is required"));
  const incomplete = validateManifestV2({
    protocolVersion: 2,
    modules: [{ id: "incomplete", file: "payload.json", profileStatus: "required" }],
    profiles: { full: {
      required: ["incomplete"], optional: [], unsupported: [], carriedForward: [],
    } },
  });
  assert.ok(incomplete.some((problem) => problem.includes("integrity.bytes")));
  assert.ok(incomplete.some((problem) => problem.includes("provenance.kind")));
});

test("v1 dual-read preserves zero-row unified statistics", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-manifest-v1-"));
  await mkdir(path.join(root, "macOS-test", "unified"), { recursive: true });
  await writeFile(path.join(root, "macOS-test", "unified", "meta.json"), JSON.stringify({
    schemaVersion: 1,
    sections: { dynamic: { file: "dynamic.json", sha256: "abc", bytes: 1, rows: 0 } },
  }));
  const manifest = await normalizeManifest({
    schemaVersion: 1,
    platform: { product: "macOS", version: "test", build: "test", architecture: "arm64" },
    fixtures: [],
  }, { osDirectory: "macOS-test", goldenDirectory: root });
  assert.equal(manifest.modules[0].statistics.rows, 0);
});
