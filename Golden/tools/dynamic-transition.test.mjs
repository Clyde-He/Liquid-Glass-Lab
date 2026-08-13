import assert from "node:assert/strict";
import test from "node:test";

import { terminalAdaptiveFaceGradeKeys } from "../learnings/dynamic-transition.mjs";

function sample(phase, progress, { black, white, clamp }) {
  return {
    phase,
    progress,
    filters: [{
      name: "glassBackground",
      inputs: {
        inputFaceColorMatrixBlack: black,
        inputFaceColorMatrixWhite: white,
        inputClamp: clamp,
      },
    }],
  };
}

function insertion(endpoint, settled) {
  return {
    slice: "core",
    cell: {
      variant: 1,
      main: true,
      appearance: "Dark",
      direction: "insertion",
      shortSide: 48,
    },
    samples: [
      sample("endpoint", 1, endpoint),
      sample("settled", 1, settled),
    ],
  };
}

function removal(preflight, trigger) {
  return {
    slice: "core",
    cell: {
      variant: 1,
      main: true,
      appearance: "Dark",
      direction: "removal",
      shortSide: 48,
    },
    samples: [
      sample("preflight", 1, preflight),
      sample("trigger", 0.9885, trigger),
    ],
  };
}

test("delegates only a measured compact terminal face-grade adaptation", () => {
  const keys = terminalAdaptiveFaceGradeKeys(insertion(
    { black: 0.4, white: 0.45, clamp: 0.7 },
    { black: 0.55, white: 0.5887, clamp: 0.9 }
  ));
  assert.deepEqual([...keys].sort(), [
    "inputFaceColorMatrixBlack",
    "inputFaceColorMatrixWhite",
  ]);
});

test("keeps single-endpoint compact channels under the strict replay bound", () => {
  const keys = terminalAdaptiveFaceGradeKeys(insertion(
    { black: 0.55, white: 0.5887, clamp: 0.7 },
    { black: 0.55, white: 0.5887, clamp: 0.9 }
  ));
  assert.deepEqual([...keys], []);
});

test("delegates a compact face grade exposed only by paired removal", () => {
  const settled = { black: 0.1, white: 0.5887, clamp: 1 };
  const keys = terminalAdaptiveFaceGradeKeys(
    insertion(settled, settled),
    removal(
      settled,
      { black: 0.5235, white: 0.5934, clamp: 1 }
    )
  );
  assert.deepEqual([...keys], ["inputFaceColorMatrixBlack"]);
});
