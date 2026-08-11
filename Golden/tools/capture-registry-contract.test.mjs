import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { goldenDirectory, readManifest } from "./lib/golden.mjs";

const source = await readFile(
  `${goldenDirectory}/../LiquidGlassLab/GlassLab/GlassLabGoldenCaptureRegistry.swift`,
  "utf8"
);
const runnerSource = await readFile(`${goldenDirectory}/tools/capture-profile.mjs`, "utf8");

const fullBlock = source.match(/static let full = Profile\(([\s\S]*?)\n    \)\n\n    static func full/)?.[1] ?? "";
const driftBlock = source.match(/static let driftScan = Profile\(([\s\S]*?)\n    \)\n}/)?.[1] ?? "";
const idsIn = (block) => [...block.matchAll(/Module\(id: "([^"]+)"/g)].map((match) => match[1]);

test("Swift Full registry matches the exact macOS 27 required profile", async () => {
  const manifest = await readManifest("macOS-27");
  assert.deepEqual(idsIn(fullBlock), manifest.profiles.full.required);
  assert.doesNotMatch(fullBlock, /driver: nil/);
});

test("macOS 26 explicitly downgrades Semantic to optional", async () => {
  const manifest = await readManifest("macOS-26");
  assert.deepEqual(manifest.profiles.full.optional, ["semantic.usage-trees"]);
  assert.match(source, /osMajor < 27/);
  assert.match(source, /optional\.availability = \.optional/);
  assert.doesNotMatch(runnerSource, /Optional \$\{id\} unavailable/);
});

test("Full validates complete staging integrity before promotion", () => {
  assert.match(runnerSource, /await recreateStagingPreservingTintCheckpoints\(staging\)/);
  assert.match(runnerSource, /const TINT_CHECKPOINT_FILES = FULL\.slice\(1, 4\)/);
  assert.match(runnerSource, /await validateStagingIntegrity\(staging\);\n  const previous/);
  assert.match(runnerSource, /sha256 mismatch/);
  assert.match(runnerSource, /on disk but unregistered/);
});

test("Drift Scan is explicitly noncanonical and nonpromotable", () => {
  assert.match(driftBlock, /canonical: false/);
  assert.match(driftBlock, /promotable: false/);
  assert.deepEqual(idsIn(driftBlock), ["drift.style-atlas", "drift.tint-sync"]);
});
