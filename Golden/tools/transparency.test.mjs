import assert from "node:assert/strict";
import test from "node:test";
import { cellKey, LEGACY_CELL_FIELDS } from "./lib/cell.mjs";
import {
  compareTransparency, transparencyProblems,
} from "./lib/transparency.mjs";
import {
  learningCoordinateDocuments, transparencyDynamicLearningDocument,
} from "./lib/golden.mjs";
import { learningAppliesToOS } from "./lib/verify-engine.mjs";

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

test("existing learnings consume only the historical experiment inside an axis archive", () => {
  const row = (glassAmount, extra = {}) => ({
    cell: { glassAmount, direction: extra.direction ?? null },
    animationMode: extra.animationMode,
    slice: extra.slice,
  });
  const documents = learningCoordinateDocuments({
    capture: {
      transparency: {
        version: 1,
        baselineAmount: 0.5,
        control: "processOverridePerObservation",
      },
    },
    static: { observations: [row(0), row(0.5), row(1)] },
    dynamic: { runs: [
      row(0.5, { animationMode: "Linear", slice: "core" }),
      row(0.5, { animationMode: "System Default", slice: "core" }),
      row(0.5, { animationMode: "Linear", slice: "backdrop", direction: "removal" }),
      row(1, { animationMode: "Linear", slice: "core" }),
    ] },
  });
  assert.equal(documents.static.observations.length, 1);
  assert.equal(documents.dynamic.runs.length, 1);
  assert.equal(documents.dynamic.runs[0].slice, "core");
});

test("axis-aware learnings can consume the complete Dynamic document", () => {
  const dynamic = { runs: [
    { cell: { glassAmount: 0 }, animationMode: "System Default", samples: [] },
    { cell: { glassAmount: 0.5 }, animationMode: "Linear", samples: [] },
    { cell: { glassAmount: 1 }, animationMode: "System Default", samples: [] },
  ] };
  const document = transparencyDynamicLearningDocument({
    capture: {
      transparency: {
        version: 1,
        baselineAmount: 0.5,
        control: "processOverridePerObservation",
      },
    },
    dynamic,
  });
  assert.equal(document.runs.length, 3);
  assert.deepEqual(document.axes.values.glassAmount, [0, 0.5, 1]);
  assert.equal(transparencyDynamicLearningDocument({ capture: {}, dynamic }), null);
});

test("OS-specific learnings are not scheduled on other archives", () => {
  const learning = { id: "macOS-27-only", osMajors: [27] };
  assert.equal(learningAppliesToOS(learning, "macOS-26"), false);
  assert.equal(learningAppliesToOS(learning, "macOS-27"), true);
  assert.equal(learningAppliesToOS({ id: "all" }, "macOS-26"), true);
});

test("legacy learning documents remain unchanged", () => {
  const staticDocument = { observations: [{ cell: {} }] };
  const dynamic = { runs: [{ cell: {} }] };
  const documents = learningCoordinateDocuments({
    capture: { schemaVersion: 2 }, static: staticDocument, dynamic,
  });
  assert.equal(documents.static, staticDocument);
  assert.equal(documents.dynamic, dynamic);
});
