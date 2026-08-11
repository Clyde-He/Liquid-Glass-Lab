import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { tintDocumentGateProblems } from "./lib/tint-compare.mjs";

const toolsDirectory = path.dirname(fileURLToPath(import.meta.url));
const goldenDirectory = path.dirname(toolsDirectory);
const compareScript = path.join(toolsDirectory, "compare.mjs");

const macOS26Directory = path.join(goldenDirectory, "macOS-26");
const macOS27Directory = path.join(goldenDirectory, "macOS-27");

test("registered comparison resolves stable module IDs", () => {
  const result = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--module=core.static-tree", "--limit=1",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).summary.fixture, "core.static-tree");
});

test("core static-tree preserves semantic Recursive assertions", () => {
  const result = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--module=core.static-tree", "--limit=1",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.summary.baselineRows, 336);
  assert.equal(report.summary.candidateRows, 336);
  assert.equal(report.summary.matchedPasses, 1_776);
  assert.equal(report.summary.missingPasses, 32);
  assert.equal(report.summary.addedPasses, 0);
});

test("Tint modules compare structure without treating coefficients as invariants", () => {
  const result = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--module=tint.sync-resolution", "--limit=1",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.summary.tintMode, "structural");
  assert.equal(report.summary.invalidMatrices, 0);
  assert.equal(report.summary.coefficientValuesCompared, false);
});

test("registered Tint file aliases retain structural gates", () => {
  const result = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--fixture=tint-sync-resolution.json", "--limit=1",
  ], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.summary.tintMode, "structural");
  assert.equal(report.summary.invalidMatrices, 0);
});

test("Tint document gates reject incomplete and failed captures", () => {
  const base = {
    complete: true, completedColorCount: 1, plan: { colors: [{}] }, rows: [],
  };
  assert.deepEqual(tintDocumentGateProblems(
    base, "tint.parameterization.sweep"
  ), []);
  assert.ok(tintDocumentGateProblems(
    { ...base, complete: false }, "tint.parameterization.sweep"
  ).some((problem) => problem.includes("complete")));
  assert.ok(tintDocumentGateProblems(
    { ...base, failure: "capture failed" }, "tint.parameterization.sweep"
  ).some((problem) => problem.includes("failure")));
  assert.ok(tintDocumentGateProblems(
    { passed: false }, "tint.sync-resolution"
  ).some((problem) => problem.includes("passed")));
});

test("unsupported dynamic comparison fails with a targeted error", () => {
  const result = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--module=core.dynamic",
  ], { encoding: "utf8" });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /core\.dynamic comparison is not implemented/);
});

test("semantic Recursive comparison ignores structural IDs for a stable repeat", () => {
  const comparison = spawnSync(process.execPath, [
    compareScript, macOS27Directory, macOS27Directory,
    "--module=core.static-tree", "--baseline-slice=core",
    "--candidate-slice=repeat", "--limit=100",
  ], { encoding: "utf8" });
  assert.equal(comparison.status, 0, comparison.stderr);
  const result = JSON.parse(comparison.stdout);
  assert.equal(result.summary.recursiveMode, "semantic");
  assert.equal(result.summary.baselineRows, 336);
  assert.equal(result.summary.candidateRows, 21);
  assert.equal(result.summary.matchedPasses, 112);
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
  const comparison = spawnSync(process.execPath, [
    compareScript, macOS26Directory, macOS27Directory,
    "--module=core.static-tree", "--limit=100",
  ], { encoding: "utf8" });
  assert.equal(comparison.status, 0, comparison.stderr);
  const result = JSON.parse(comparison.stdout);
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
  const comparison = spawnSync(process.execPath, [
    compareScript, macOS27Directory, macOS27Directory,
    "--baseline-module=control.recursive-display-context",
    "--candidate-module=core.static-tree", "--limit=100",
  ], { encoding: "utf8" });
  assert.equal(comparison.status, 0, comparison.stderr);
  const result = JSON.parse(comparison.stdout);
  assert.equal(result.summary.matchedPasses, 1_776);
  assert.equal(result.summary.missingPasses, 0);
  assert.equal(result.summary.addedPasses, 0);
  assert.equal(result.summary.missingProperties, 0);
  assert.equal(result.summary.addedProperties, 0);
  assert.ok(result.summary.changedValues > 0);
  assert.equal(result.summary.rawTopologyChangedRows, 0);
  assert.equal(result.summary.rawValueChangedRows, 336);
  assert.ok(result.propertyValueChanges.some(
    ({ family, property }) => family === "glassBackground"
      && property === "inputKeyFillHighlightEffectOffset"
  ));
});

test("raw Recursive mode remains available", () => {
  const comparison = spawnSync(process.execPath, [
    compareScript, macOS27Directory, macOS27Directory,
    "--module=core.static-tree", "--baseline-slice=core",
    "--candidate-slice=repeat", "--recursive-mode=raw", "--limit=100",
  ], { encoding: "utf8" });
  assert.equal(comparison.status, 0, comparison.stderr);
  const result = JSON.parse(comparison.stdout);
  assert.equal(result.summary.recursiveMode, "raw");
  assert.equal(result.summary.missingFields, 0);
  assert.equal(result.summary.addedFields, 0);
  assert.equal(result.summary.missingRows, 315);
  assert.equal(result.summary.changedValues, 21);
  assert.equal(result.summary.topologyChangedRows, 0);
  assert.equal(result.summary.valueChangedRows, 0);
});
