import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { goldenDirectory, readManifest } from "./lib/golden.mjs";

const source = await readFile(
  `${goldenDirectory}/../LiquidGlassLab/GlassLab/GlassLabGoldenCaptureRegistry.swift`,
  "utf8"
);

const fullBlock = source.match(/static let full = Profile\(([\s\S]*?)\n    \)\n\n    static let driftScan/)?.[1] ?? "";
const driftBlock = source.match(/static let driftScan = Profile\(([\s\S]*?)\n    \)\n}/)?.[1] ?? "";
const idsIn = (block) => [...block.matchAll(/Module\(id: "([^"]+)"/g)].map((match) => match[1]);

test("Swift Full registry matches the exact macOS 27 required profile", async () => {
  const manifest = await readManifest("macOS-27");
  assert.deepEqual(idsIn(fullBlock), manifest.profiles.full.required);
  assert.doesNotMatch(fullBlock, /driver: nil/);
});

test("Drift Scan is explicitly noncanonical and nonpromotable", () => {
  assert.match(driftBlock, /canonical: false/);
  assert.match(driftBlock, /promotable: false/);
  assert.deepEqual(idsIn(driftBlock), ["drift.style-atlas", "drift.tint-sync"]);
});
