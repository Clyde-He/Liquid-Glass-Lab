import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const goldenDirectory = path.dirname(fileURLToPath(import.meta.url));
const compareScript = path.join(goldenDirectory, "compare.mjs");

function runComparison(baselineFile, candidateFile, ...options) {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "glass-compare-"));
  const baselineDirectory = path.join(temporaryDirectory, "baseline");
  const candidateDirectory = path.join(temporaryDirectory, "candidate");
  fs.mkdirSync(baselineDirectory);
  fs.mkdirSync(candidateDirectory);
  fs.symlinkSync(
    baselineFile,
    path.join(baselineDirectory, "recursive-pass-audit.json")
  );
  fs.symlinkSync(
    candidateFile,
    path.join(candidateDirectory, "recursive-pass-audit.json")
  );

  try {
    const result = spawnSync(process.execPath, [
      compareScript,
      baselineDirectory,
      candidateDirectory,
      "--fixture=recursive-pass-audit.json",
      "--limit=100",
      ...options,
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

const macOS26 = path.join(goldenDirectory, "macOS-26", "recursive-pass-audit.json");
const macOS27 = path.join(goldenDirectory, "macOS-27", "recursive-pass-audit.json");
const macOS27Repeat = path.join(
  goldenDirectory,
  "macOS-27",
  "recursive-pass-audit-stability-repeat.json"
);
const macOS27DisplayContrast = path.join(
  goldenDirectory,
  "macOS-27",
  "recursive-pass-audit-display-context-a.json"
);

test("semantic Recursive comparison ignores structural IDs for a stable repeat", () => {
  const result = runComparison(macOS27, macOS27Repeat);
  assert.equal(result.summary.recursiveMode, "semantic");
  assert.equal(result.summary.matchedPasses, 1_776);
  assert.equal(result.summary.missingPasses, 0);
  assert.equal(result.summary.addedPasses, 0);
  assert.equal(result.summary.missingFields, 0);
  assert.equal(result.summary.addedFields, 0);
  assert.equal(result.summary.changedValues, 0);
  assert.equal(result.summary.volatileChangedValues, 0);
  assert.equal(result.summary.rawTopologyChangedRows, 0);
  assert.equal(result.summary.rawValueChangedRows, 0);
  assert.deepEqual(result.passInventoryChanges, []);
  assert.deepEqual(result.passClassChanges, []);
  assert.deepEqual(result.propertyInventoryChanges, []);
});

test("semantic Recursive comparison isolates the macOS 26 to 27 pass delta", () => {
  const result = runComparison(macOS26, macOS27);
  assert.equal(result.summary.baselinePasses, 1_808);
  assert.equal(result.summary.candidatePasses, 1_776);
  assert.equal(result.summary.matchedPasses, 1_776);
  assert.equal(result.summary.missingPasses, 32);
  assert.equal(result.summary.addedPasses, 0);
  assert.equal(result.summary.addedProperties, 7_552);
  assert.equal(result.summary.passObjectClassChanges, 304);
  assert.deepEqual(
    result.passInventoryChanges.map(({ kind, channel, family, count }) => ({
      kind, channel, family, count,
    })),
    [
      {
        kind: "missing",
        channel: "compositingFilter",
        family: "screenBlendMode",
        count: 16,
      },
      {
        kind: "missing",
        channel: "effect",
        family: "CASDFFillEffect",
        count: 16,
      },
    ]
  );
  assert.deepEqual(result.passClassChanges, [
    {
      field: "objectClass",
      channel: "filters",
      family: "glassBackground",
      before: "CAFilter",
      after: "DLCAFilter",
      count: 304,
      rowCount: 304,
    },
  ]);
  assert.equal(result.propertyInventoryChanges.length, 25);
});

test("semantic Recursive comparison preserves display-sensitive value evidence", () => {
  const result = runComparison(macOS27DisplayContrast, macOS27);
  assert.equal(result.summary.matchedPasses, 1_776);
  assert.equal(result.summary.missingPasses, 0);
  assert.equal(result.summary.addedPasses, 0);
  assert.equal(result.summary.missingProperties, 0);
  assert.equal(result.summary.addedProperties, 0);
  assert.equal(result.summary.changedValues, 634);
  assert.equal(result.summary.rawTopologyChangedRows, 0);
  assert.equal(result.summary.rawValueChangedRows, 268);
  assert.deepEqual(
    result.propertyValueChanges.map(({ family, property, count }) => ({
      family, property, count,
    })),
    [
      {
        family: "glassBackground",
        property: "inputKeyFillHighlightEffectOffset",
        count: 268,
      },
      {
        family: "glassBackground",
        property: "inputKeyFillHighlightHeight",
        count: 212,
      },
      {
        family: "CASDFOutputEffect",
        property: "maximum",
        count: 154,
      },
    ]
  );
});

test("raw Recursive mode remains available", () => {
  const result = runComparison(macOS27, macOS27Repeat, "--recursive-mode=raw");
  assert.equal(result.summary.recursiveMode, "raw");
  assert.equal(result.summary.missingFields, 0);
  assert.equal(result.summary.addedFields, 0);
  assert.equal(result.summary.changedValues, 0);
});
