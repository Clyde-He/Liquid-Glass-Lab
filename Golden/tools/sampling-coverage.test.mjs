import assert from "node:assert/strict";
import test from "node:test";
import { comparableSampling, samplingProblems } from "./lib/sampling-coverage.mjs";
const sample = scale => ({ layerLines: ["  CABackdropLayer frame=(0,0,100,100)"],
  backdropSampling: [{ path: "root.backdrop", scale, marginWidth: 16 }], filters: [] });

test("sampling validation rejects missing, unreadable and incomplete layer coverage", () => {
  assert.deepEqual(samplingProblems(sample(0.25)), []);
  for (const scale of [null, 0, -1, "0.25", NaN]) assert.ok(samplingProblems(sample(scale)).length);
  const missing = sample(0.25);
  delete missing.backdropSampling;
  assert.ok(samplingProblems(missing).length);
  missing.backdropSampling = [];
  assert.ok(samplingProblems(missing).length);
});

test("sampling comparison preserves measured changes and separates legacy gaps", () => {
  const left = { runs: [{ samples: [sample(0.25)] }] };
  const right = { runs: [{ samples: [sample(0.125)] }] };
  let compared = comparableSampling(left, right);
  assert.equal(compared.coverage.complete, true);
  assert.notDeepEqual(compared.baseline, compared.candidate);
  delete left.runs[0].samples[0].backdropSampling;
  compared = comparableSampling(left, right);
  assert.equal(compared.coverage.missingComparisons, 1);
  assert.deepEqual(compared.baseline, compared.candidate);
  assert.equal(right.runs[0].samples[0].backdropSampling[0].scale, 0.125);
});
