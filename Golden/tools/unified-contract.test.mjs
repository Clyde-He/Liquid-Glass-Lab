import assert from "node:assert/strict";
import test from "node:test";

import dynamicLearnings from "../learnings/dynamic-transition.mjs";
import staticRecipeLearnings from "../learnings/static-recipe.mjs";
import staticTopologyLearnings from "../learnings/static-topology.mjs";
import {
  endpointSample, makeExpect, normalizeUnifiedDocument, tintComponents,
} from "./lib/golden.mjs";
import { cellKey, makeCell } from "./lib/cell.mjs";

const runLearning = (learnings, id, sections) => {
  const learning = learnings.find((item) => item.id === id);
  assert.ok(learning, `missing learning ${id}`);
  learning.verify({ sections, expect: makeExpect([]) });
};

test("cell identity and derived axes include real key participation", () => {
  const neither = makeCell({
    variant: 1,
    main: false,
    key: false,
    subdued: false,
  });
  const key = makeCell({
    variant: 1,
    main: false,
    key: true,
    subdued: false,
  });
  assert.notEqual(cellKey(neither), cellKey(key));

  const document = normalizeUnifiedDocument({
    rows: [{ cell: neither }, { cell: key }],
  });
  assert.deepEqual(document.axes.values.key, [false, true]);
  assert.ok(document.axes.swept.includes("key"));
});

test("direct and transcoded Tint component shapes normalize identically", () => {
  const components = [0.1, 0.2, 0.3, 0.5];
  assert.deepEqual(tintComponents({ tintComponents: components }), components);
  assert.deepEqual(tintComponents({ tint: { components } }), components);
});

test("endpoint selection prefers the final settled sample after early saturation", () => {
  const early = { phase: "sample", progress: 1, marker: "still settling" };
  const settled = { phase: "settled", progress: 1, marker: "resolved" };
  assert.equal(endpointSample({ samples: [early, settled] }), settled);
});

test("direct static tree keeps the 336-cell product plus 21 repeat rows", () => {
  const rows = [];
  const subvariants = [null, "menu", "sheet", "camera"];
  for (let variant = 0; variant < 21; variant += 1) {
    for (const subvariant of subvariants) {
      for (const main of [false, true]) {
        for (const subdued of [false, true]) {
          rows.push({
            cell: makeCell({
              variant,
              subvariant,
              main,
              key: false,
              subdued,
              appearance: "Light",
              backdrop: "Light",
              tint: "None",
              width: 480,
              height: 200,
              cornerRadius: 16,
              host: "Panel",
              direction: null,
            }),
            accepted: true,
            participation: main ? "main" : "neither",
            slice: "core",
            topologySignature: `topology-${variant}-${subdued}`,
            valueSignature: `value-${variant}-${subvariant}-${main}-${subdued}`,
            layers: {},
            passes: {},
          });
        }
      }
    }
  }
  for (let variant = 0; variant < 21; variant += 1) {
    const original = rows.find(
      (row) =>
        row.cell.variant === variant
        && row.cell.subvariant === null
        && row.cell.main === true
        && row.cell.subdued === false
    );
    rows.push({ ...original, slice: "repeat" });
  }

  const document = normalizeUnifiedDocument({ rows });
  const sections = { "static-tree": document };
  runLearning(
    staticTopologyLearnings,
    "static-tree-covers-the-variant-product",
    sections
  );
  runLearning(
    staticTopologyLearnings,
    "static-tree-repeat-agrees-with-core",
    sections
  );
});

test("direct key slice is compared with the Main active Recipe", () => {
  const payload = {
    inputs: { inputFaceOpacity: 1, inputBleedOpacity: 0.5 },
    highlight: { opacity: 1 },
    geometry: { marginWidth: 40 },
    colors: {},
    points: {},
    strings: {},
  };
  const rows = [];
  for (const variant of [1, 2]) {
    for (const subdued of [false, true]) {
      const common = {
        variant,
        subvariant: null,
        subdued,
        appearance: "Light",
        backdrop: "Light",
        tint: "None",
        width: 480,
        height: 200,
        cornerRadius: 16,
        host: "Panel",
        direction: null,
      };
      rows.push({
        cell: makeCell({ ...common, main: true, key: false }),
        accepted: true,
        participation: "main",
        slice: "core",
        ...payload,
      });
      rows.push({
        cell: makeCell({ ...common, main: false, key: true }),
        accepted: true,
        participation: "key",
        slice: "key",
        ...payload,
      });
    }
  }
  runLearning(
    staticRecipeLearnings,
    "real-key-participation-selects-the-active-recipe",
    { "static-scalar": normalizeUnifiedDocument({ rows }) }
  );
});

test("direct dynamic repeat uses slice as its sweep provenance", () => {
  const cell = makeCell({
    variant: 1,
    subvariant: null,
    main: false,
    key: false,
    subdued: null,
    appearance: "Light",
    backdrop: "Light",
    tint: "None",
    width: 480,
    height: 200,
    cornerRadius: 16,
    host: "Panel",
    direction: "insertion",
  });
  const sample = {
    progress: 1,
    filters: [{
      name: "glassBackground",
      inputs: { inputFaceOpacity: "1", inputBlurRadius: "4" },
    }],
    effects: [],
    layerLines: [],
  };
  const run = (slice) => ({
    cell,
    accepted: true,
    slice,
    samples: [sample],
  });
  runLearning(
    dynamicLearnings,
    "repeated-cells-agree-across-sweeps",
    {
      dynamic: normalizeUnifiedDocument({
        runs: [run("core"), run("repeat")],
      }),
    }
  );
});
