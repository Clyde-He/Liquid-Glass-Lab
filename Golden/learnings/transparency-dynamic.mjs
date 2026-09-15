// macOS 27 System Default Materialize / Dissolve timing across the adjustable
// Liquid Glass amount axis.
//
// Source: Documentation/GlassTransparencyStudy.md — Dynamic interpolation;
// Golden/CAPTURE-SPEC.md — Dynamic.

import { progressOf } from "../tools/lib/golden.mjs";
import { CELL_FIELDS, LEGACY_CELL_FIELDS, cellKey } from "../tools/lib/cell.mjs";

const SECTION = "dynamic-transparency";
const AMOUNTS = [0, 0.5, 1];
const SAMPLE_FRACTIONS = [0.125, 0.25, 0.5, 0.75, 0.875];
const LIFECYCLE_FIELDS = CELL_FIELDS.filter((field) => field !== "direction");

const coordinateKey = (run, fields) => `${run.slice}\0${cellKey(run.cell, fields)}`;

function groupsBy(runs, keyOf) {
  const groups = new Map();
  for (const run of runs) {
    const key = keyOf(run);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(run);
  }
  return groups;
}

function sampleAt(run, phase, requestedProgress) {
  return (run.samples ?? []).find((sample) =>
    sample.phase === phase && sample.requestedProgress === requestedProgress
  ) ?? null;
}

const observedProgress = (run, phase, requestedProgress) =>
  progressOf(sampleAt(run, phase, requestedProgress));

export default [
  {
    id: "system-default-timing-is-stable-across-glass-amounts",
    claim:
      "On macOS 27, System Default Materialize and Dissolve use one front-loaded, "
      + "approximately reversible progress envelope at Glass amounts 0, 0.5, and 1. "
      + "Changing the amount does not select another timing law",
    source: "GlassTransparencyStudy.md — Dynamic interpolation",
    osMajors: [27],
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = (sections[SECTION].runs ?? []).filter(
        ({ animationMode }) => animationMode === "System Default"
      );
      expect.equal(runs.length, 72, "System Default runs");
      expect.equal(runs.filter(({ accepted }) => !accepted).length, 0, "rejected runs");

      for (const amount of AMOUNTS) {
        expect.equal(
          runs.filter(({ cell }) => cell.glassAmount === amount).length,
          24,
          `runs at Glass amount ${amount}`
        );
      }
      for (const direction of ["insertion", "removal"]) {
        expect.equal(
          runs.filter(({ cell }) => cell.direction === direction).length,
          36,
          `${direction} runs`
        );
      }

      const amountGroups = groupsBy(
        runs,
        (run) => coordinateKey(run, LEGACY_CELL_FIELDS)
      );
      expect.equal(amountGroups.size, 24, "logical direction coordinates");
      const incompleteAmountGroups = [...amountGroups.values()].filter((members) =>
        AMOUNTS.some((amount) => !members.some(({ cell }) => cell.glassAmount === amount))
      );
      expect.equal(incompleteAmountGroups.length, 0, "coordinates missing a Glass amount");

      const expectedLifecycle = [
        ["preflight", 0], ["trigger", 0],
        ...SAMPLE_FRACTIONS.map((fraction) => ["sample", fraction]),
        ["endpoint", 1], ["settled", 1],
      ];
      const malformedLifecycles = runs.filter((run) =>
        run.samples?.length !== expectedLifecycle.length
          || expectedLifecycle.some(([phase, requestedProgress], index) => {
            const sample = run.samples[index];
            return sample?.phase !== phase || sample.requestedProgress !== requestedProgress;
          })
      );
      expect.equal(malformedLifecycles.length, 0, "runs without the nine-sample lifecycle");

      const nonMonotonic = runs.filter((run) => {
        const values = run.samples.map(progressOf).filter(Number.isFinite);
        return values.slice(1).some((value, index) =>
          run.cell.direction === "insertion"
            ? value < values[index]
            : value > values[index]
        );
      });
      expect.equal(nonMonotonic.length, 0, "non-monotonic progress traces");

      const insertion = runs.filter(({ cell }) => cell.direction === "insertion");
      const expectedEnvelope = new Map([
        [0.125, { center: 0.35, tolerance: 0.06 }],
        [0.25, { center: 0.71, tolerance: 0.04 }],
        [0.5, { center: 0.958, tolerance: 0.02 }],
        [0.75, { center: 0.994, tolerance: 0.01 }],
        [0.875, { center: 0.998, tolerance: 0.005 }],
      ]);
      for (const [fraction, { center, tolerance }] of expectedEnvelope) {
        expect.maxBelow(
          insertion,
          (run) => Math.abs(observedProgress(run, "sample", fraction) - center),
          tolerance,
          `insertion timing deviation at t=${fraction}`
        );
      }

      const amountSpreads = [];
      for (const [key, members] of amountGroups) {
        for (const [phase, requestedProgress] of expectedLifecycle) {
          const values = members
            .map((run) => observedProgress(run, phase, requestedProgress))
            .filter(Number.isFinite);
          if (values.length !== AMOUNTS.length) continue;
          amountSpreads.push({
            key,
            phase,
            requestedProgress,
            spread: Math.max(...values) - Math.min(...values),
          });
        }
      }
      expect.maxBelow(
        amountSpreads,
        ({ spread }) => spread,
        0.05,
        "worst timing spread across Glass amounts"
      );

      const lifecycleGroups = groupsBy(
        runs,
        (run) => coordinateKey(run, LIFECYCLE_FIELDS)
      );
      expect.equal(lifecycleGroups.size, 36, "amount-specific lifecycle coordinates");
      expect.equal(
        [...lifecycleGroups.values()].filter((members) =>
          !members.some(({ cell }) => cell.direction === "insertion")
            || !members.some(({ cell }) => cell.direction === "removal")
        ).length,
        0,
        "lifecycles missing insertion or removal"
      );
      const reversibilityErrors = [];
      for (const [key, members] of lifecycleGroups) {
        const insertionRun = members.find(({ cell }) => cell.direction === "insertion");
        const removalRun = members.find(({ cell }) => cell.direction === "removal");
        if (!insertionRun || !removalRun) continue;
        for (const [phase, requestedProgress] of expectedLifecycle) {
          const forward = observedProgress(insertionRun, phase, requestedProgress);
          const reverse = observedProgress(removalRun, phase, requestedProgress);
          if (!Number.isFinite(forward) || !Number.isFinite(reverse)) continue;
          reversibilityErrors.push({
            key,
            phase,
            requestedProgress,
            error: Math.abs(forward + reverse - 1),
          });
        }
      }
      expect.maxBelow(
        reversibilityErrors,
        ({ error }) => error,
        0.05,
        "worst insertion/removal complement error"
      );

      expect.equal(
        runs.filter(({ maximumAttachedAnimationDuration }) =>
          maximumAttachedAnimationDuration !== 0
        ).length,
        0,
        "runs exposing an attached CAAnimation duration"
      );
    },
  },
];
