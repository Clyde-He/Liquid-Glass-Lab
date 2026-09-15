import assert from "node:assert/strict";
import test from "node:test";
import { cellKey, LEGACY_CELL_FIELDS } from "./lib/cell.mjs";
import {
  compareTransparency, transparencyProblems,
} from "./lib/transparency.mjs";

test("transparency provenance distinguishes fixed and canonical-axis captures", () => {
  const fixed = { version: 1, amount: 0.5, control: "processOverride" };
  const axis = {
    version: 1,
    baselineAmount: 0.5,
    control: "processOverridePerObservation",
  };
  assert.deepEqual(transparencyProblems(fixed), []);
  assert.deepEqual(transparencyProblems(axis), []);
  assert.ok(transparencyProblems({ ...axis, amount: 0.5 }).length > 0);
  assert.ok(transparencyProblems({ ...fixed, baselineAmount: 0.5 }).length > 0);
});

test("legacy archives compare against only the canonical midpoint projection", () => {
  const axis = {
    transparency: {
      version: 1,
      baselineAmount: 0.5,
      control: "processOverridePerObservation",
    },
  };
  const comparison = compareTransparency({}, axis);
  assert.equal(comparison.comparable, true);
  assert.equal(comparison.status, "legacy-baseline-projection");
  assert.equal(comparison.projectionAmount, 0.5);
  assert.equal(comparison.baselineMode, "legacy");
  assert.equal(comparison.candidateMode, "axis");
});

test("glassAmount joins macOS 27 rows without changing the legacy coordinate", () => {
  const cell = {
    variant: 1, subvariant: null, main: true, key: false, subdued: false,
    appearance: "Light", backdrop: "Light", tint: "None", width: 480,
    height: 200, cornerRadius: 16, host: "Panel", direction: null,
  };
  assert.notEqual(cellKey({ ...cell, glassAmount: 0.25 }), cellKey({
    ...cell, glassAmount: 0.5,
  }));
  assert.equal(
    cellKey({ ...cell, glassAmount: 0.25 }, LEGACY_CELL_FIELDS),
    cellKey({ ...cell, glassAmount: 0.5 }, LEGACY_CELL_FIELDS)
  );
});
