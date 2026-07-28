// Dynamic behaviour of Regular and Clear during Materialize / Dissolve.
//
// Source: Documentation/GlassResearchRoadmap.md — "P1.1 / Full environment
// matrix and baseline-driven curve" and "P1.1 / Geometry spot check".
//
// The dynamic section merges what used to be two fixtures — the environment
// matrix and the geometry sweep — because they sample the same thing along
// different axes. Coverage is therefore asserted from the declared axes rather
// than from a run count, so adding an axis does not falsify the coverage claim.

import {
  ALL_CHANNELS, channelTable, endpointSample, geometryInflation, glassBackground,
  numeric, progressOf, resolveChannel,
} from "../tools/lib/golden.mjs";
import { CELL_FIELDS, cellKey, isClearCell } from "../tools/lib/cell.mjs";

const SECTION = "dynamic";

const endpointInputs = (run) => glassBackground(endpointSample(run))?.inputs ?? null;

/**
 * Pairs runs that differ only in `axis`. Every other cell field must match, so
 * a pair isolates that axis even when several sweeps are merged and a cell is
 * covered more than once.
 */
function pairsAcross(runs, axis) {
  const others = CELL_FIELDS.filter((field) => field !== axis);
  const groups = new Map();
  for (const run of runs) {
    const key = cellKey(run.cell, others);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(run);
  }
  const pairs = [];
  for (const [key, members] of groups) {
    for (let i = 0; i < members.length; i += 1) {
      for (let j = i + 1; j < members.length; j += 1) {
        if (members[i].cell[axis] === members[j].cell[axis]) continue;
        pairs.push({ key, a: members[i], b: members[j] });
      }
    }
  }
  return pairs;
}

/** Channels on which two settled endpoints disagree. */
function endpointDelta(a, b) {
  const left = endpointInputs(a);
  const right = endpointInputs(b);
  if (!left || !right) return null;
  const changed = [];
  for (const key of Object.keys(left)) {
    if (!(key in right)) continue;
    const x = numeric(left[key]);
    const y = numeric(right[key]);
    if (x === null || y === null) continue;
    if (Math.abs(x - y) > 1e-9) changed.push(key);
  }
  return changed;
}

const layerClasses = (run) =>
  [...new Set(
    run.samples.flatMap((sample) =>
      (sample.layerLines ?? []).map((line) => String(line).trim().split(" ")[0])
    )
  )].sort().join(">");

export default [
  {
    id: "dynamic-covers-the-curve-axes",
    claim:
      "Every run is context-accepted, samples a full 0-to-1 progress span, and "
      + "the section sweeps each axis the curve depends on: material, "
      + "participation, appearance, backdrop, tint, size, and direction",
    source: "GlassResearchRoadmap.md — P1.1",
    sections: [SECTION],
    verify({ sections, expect }) {
      const document = sections[SECTION];
      const runs = document.runs ?? [];
      expect.ok(runs.length > 0, "runs", `${runs.length}`);
      expect.equal(runs.filter((run) => !run.accepted).length, 0, "rejected runs");

      const required = [
        "variant", "main", "appearance", "backdrop", "tint", "height", "direction",
      ];
      const missing = required.filter(
        (axis) => (document.axes.values[axis] ?? []).length < 2
      );
      expect.equal(missing.join(",") || "none", "none", "axes swept with <2 values");

      const spans = runs.map((run) => {
        const progresses = run.samples
          .map(progressOf)
          .filter((value) => value !== null);
        return { min: Math.min(...progresses), max: Math.max(...progresses), run };
      });
      expect.maxBelow(spans, (item) => item.min, 0.1, "worst lowest sampled g");
      expect.maxBelow(spans, (item) => 1 - item.max, 1e-6, "worst distance of top g from 1");
    },
  },

  {
    id: "repeated-cells-agree-across-capture-sessions",
    claim:
      "Four cells were captured twice, in separate sessions, by the two sweeps "
      + "that the dynamic section merges. Their settled endpoints agree on "
      + "every channel — the only cross-session repeatability evidence the "
      + "dynamic archive has, which is why the overlap is kept rather than "
      + "deduplicated",
    source: "GlassResearchRoadmap.md — P1.1",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const groups = new Map();
      for (const run of runs) {
        const key = cellKey(run.cell);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(run);
      }
      const repeated = [...groups.values()].filter((members) => members.length > 1);
      expect.requireSamples(repeated.length, 1, "cells captured more than once");

      const differing = [];
      for (const members of repeated) {
        expect.ok(
          new Set(members.map((run) => run.source)).size === members.length,
          "repeats come from distinct sweeps",
          members.map((run) => run.source).join(" + ")
        );
        for (let i = 1; i < members.length; i += 1) {
          const delta = endpointDelta(members[0], members[i]);
          if (delta === null) continue;
          differing.push(...delta);
        }
      }
      expect.equal(differing.length, 0, "channels differing between repeats");
    },
  },

  {
    id: "backdrop-does-not-reach-model-state",
    claim:
      "Backdrop luminance changes no model-side value. Adaptation happens in "
      + "the render server via inputBackdropAware and never appears in the model",
    source: "GlassResearchRoadmap.md — P1.1, finding 1",
    sections: [SECTION],
    verify({ sections, expect }) {
      const pairs = pairsAcross(sections[SECTION].runs ?? [], "backdrop");
      expect.requireSamples(pairs.length, 24, "backdrop pairs");
      const differences = [];
      for (const pair of pairs) {
        const delta = endpointDelta(pair.a, pair.b);
        if (delta === null) continue;
        for (const channel of delta) differences.push({ key: pair.key, channel });
      }
      expect.equal(differences.length, 0, "channels differing by backdrop");
    },
  },

  {
    id: "appearance-moves-endpoints",
    claim:
      "Appearance moves endpoints, so it cannot be folded away — but only for "
      + "three of the four material/participation combinations. Clear under "
      + "Main resolves an appearance-independent glassBackground; its only "
      + "appearance-dependent channel is the bleed-darken flag, which agrees at "
      + "the endpoint and differs mid-transition",
    source: "GlassResearchRoadmap.md — P1.1, finding 2",
    sections: [SECTION],
    verify({ sections, expect }) {
      const pairs = pairsAcross(sections[SECTION].runs ?? [], "appearance");
      expect.requireSamples(pairs.length, 24, "appearance pairs");

      const invariant = [];
      let compared = 0;
      for (const pair of pairs) {
        const delta = endpointDelta(pair.a, pair.b);
        if (delta === null) continue;
        compared += 1;
        if (delta.length === 0) invariant.push(pair);
      }
      expect.ok(compared > 0, "comparable appearance pairs", `${compared}`);

      const unexpected = invariant.filter(
        (pair) => !(isClearCell(pair.a.cell) && pair.a.cell.main === true)
      );
      expect.equal(unexpected.length, 0, "appearance-invariant pairs outside Clear+Main");
      expect.ok(
        invariant.length > 0,
        "Clear+Main pairs invariant on glassBackground",
        `${invariant.length} of ${compared}`
      );
      expect.ok(
        compared - invariant.length > 0,
        "pairs whose glassBackground endpoints differ",
        `${compared - invariant.length}`
      );
    },
  },

  {
    id: "topology-is-environment-invariant",
    claim:
      "No environment axis changes the layer topology of the transition. Tint "
      + "adds a CASDFGradientEffect to an existing layer rather than a layer, so "
      + "even the tinted branch leaves the class inventory untouched",
    source: "GlassResearchRoadmap.md — P1.1, finding 4",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const signatures = new Set(runs.map(layerClasses));
      expect.equal(signatures.size, 1, "distinct layer-class inventories");

      const gradientRuns = runs.filter((run) =>
        run.samples.some((sample) =>
          (sample.effects ?? []).some((e) => e.effectClass === "CASDFGradientEffect")
        )
      );
      const tinted = runs.filter((run) => run.cell.tint !== "None");
      expect.equal(
        gradientRuns.length,
        tinted.length,
        "runs carrying a gradient effect vs tinted runs"
      );
      expect.equal(
        gradientRuns.filter((run) => run.cell.tint === "None").length,
        0,
        "untinted runs carrying a gradient effect"
      );
    },
  },

  {
    id: "tint-alpha-is-quadratic-in-progress",
    claim:
      "Tint matrix coefficient 18 follows sourceAlpha × g², not a linear ramp. "
      + "A linear model misses by up to 0.25",
    source: "GlassResearchRoadmap.md — P1.1 Tint routing addendum, finding 4",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const pattern = /ColorMatrix4x5\(\[([^\]]+)\];sha256=[0-9a-f]+\)/;
      const residuals = [];

      for (const run of runs) {
        const alpha = run.tint?.components?.[3];
        if (!Number.isFinite(alpha)) continue;
        for (const sample of run.samples ?? []) {
          const gradient = (sample.effects ?? []).find(
            (effect) => effect.effectClass === "CASDFGradientEffect"
          );
          if (!gradient) continue;
          const matrix = (sample.filters ?? []).find(
            (filter) =>
              filter.path === gradient.path && filter.name === "vibrantColorMatrix"
          );
          const raw = matrix?.inputs?.inputColorMatrix;
          const match = typeof raw === "string" ? raw.match(pattern) : null;
          if (!match) continue;
          const coefficients = match[1].split(",").map(Number);
          if (coefficients.length !== 20) continue;
          const g = progressOf(sample);
          if (g === null) continue;
          residuals.push({ residual: Math.abs(coefficients[18] - alpha * g * g), g, alpha });
        }
      }

      expect.requireSamples(residuals.length, 128, "tinted samples");
      expect.maxBelow(residuals, (item) => item.residual, 1e-4, "worst |coefficient18 - a·g²|");
    },
  },

  {
    id: "curve-replays-from-read-endpoints",
    claim:
      "Reading endpoints from the Recipe and applying the five dimensionless "
      + "shapes reproduces the system transition. Away from the baseline "
      + "geometry the error stays inside min(5%, 4/shortSide), the bound "
      + "implied by a mis-classified linear-vs-height channel",
    source: "GlassResearchRoadmap.md — P1.1, baseline-driven curve",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const perSize = new Map();
      let comparisons = 0;

      for (const run of runs) {
        if (run.cell.tint !== "None") continue;
        const endpoint = endpointInputs(run);
        if (!endpoint) continue;
        const clear = isClearCell(run.cell);
        const main = run.cell.main === true;
        const light = run.cell.appearance === "Light";
        const short = run.cell.shortSide;
        const inflation = geometryInflation(short);
        const table = channelTable({ clear, main });

        for (const sample of run.samples ?? []) {
          const inputs = glassBackground(sample)?.inputs;
          const g = progressOf(sample);
          if (!inputs || g === null) continue;

          for (const [key, channel] of Object.entries(table)) {
            const end = numeric(endpoint[key]);
            const actual = numeric(inputs[key]);
            if (end === null || actual === null) continue;
            comparisons += 1;
            const predicted = resolveChannel(channel, g, end, inflation);
            const scale = Math.max(1, Math.abs(end - channel.start));
            const error = Math.abs(actual - predicted) / scale;
            const worst = perSize.get(short);
            if (!worst || error > worst.error) {
              perSize.set(short, { error, key, g: Number(g.toFixed(3)) });
            }
          }

          // The one discrete edge: Clear in DarkAqua steps at the midpoint.
          const end = numeric(endpoint.inputBleedDarkenBlend);
          const actual = numeric(inputs.inputBleedDarkenBlend);
          if (end !== null && actual !== null) {
            const predicted = clear && !light ? (g < 0.5 ? 0 : end) : end;
            expect.ok(
              Math.abs(predicted - actual) < 1e-9,
              "inputBleedDarkenBlend discrete edge",
              `g=${g.toFixed(3)} expected ${predicted}, got ${actual}`
            );
          }
        }
      }

      expect.requireSamples(comparisons, 10_000, "channel comparisons");
      for (const [short, worst] of [...perSize].sort((a, b) => a[0] - b[0])) {
        const bound = Math.min(0.05, 4 / short);
        expect.ok(
          worst.error <= bound * 1.05,
          `shortSide ${short} within min(5%, 4/S)`,
          `worst ${(worst.error * 100).toFixed(3)}% on ${worst.key} `
            + `(bound ${(bound * 100).toFixed(2)}%)`
        );
      }
    },
  },

  {
    id: "sdf-element-inflates-during-materialize",
    claim:
      "Materialize inflates the CASDFElementLayer short side by "
      + "min(0.2 · shortSide, 16) points and retracts it linearly with g. This "
      + "is the mechanism behind the size-dependent shape term",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const deviations = [];

      for (const run of runs) {
        const rest = run.cell.shortSide;
        const inflation = Math.min(0.2 * rest, 16);
        for (const sample of run.samples ?? []) {
          const g = progressOf(sample);
          if (g === null) continue;
          let widest = null;
          for (const line of sample.layerLines ?? []) {
            const match = String(line).match(
              /CASDFElementLayer\b[^=]*frame=\([-0-9.]+, [-0-9.]+, ([0-9.]+), ([0-9.]+)\)/
            );
            if (!match) continue;
            const short = Math.min(Number(match[1]), Number(match[2]));
            if (short >= 1 && (widest === null || short > widest)) widest = short;
          }
          if (widest === null) continue;
          deviations.push({
            deviation: Math.abs(widest - (rest + inflation * (1 - g))),
            rest,
            g: Number(g.toFixed(3)),
          });
        }
      }

      expect.requireSamples(deviations.length, 18, "observed element frames");
      expect.maxBelow(
        deviations,
        (item) => item.deviation,
        0.06,
        "worst |observed - min(0.2·S,16) model| in points"
      );
    },
  },

  {
    id: "endpoints-scale-with-short-side",
    claim:
      "Endpoints track shortSide, which is why the curve reads them instead of "
      + "authoring them: bleed 0.35·S, shadow height 0.4·S, outer refraction 0.2·S",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const sizes = new Set(runs.map((run) => run.cell.shortSide));
      expect.requireSamples(sizes.size, 2, "distinct short sides");

      const ratios = {
        inputBleedAmount: 0.35,
        inputShadowHeight: 0.4,
        inputOuterRefractionAmount: 0.2,
      };
      const errors = [];
      for (const run of runs) {
        const endpoint = endpointInputs(run);
        if (!endpoint) continue;
        const short = run.cell.shortSide;
        for (const [key, ratio] of Object.entries(ratios)) {
          const actual = numeric(endpoint[key]);
          // Clear carries no bleed, and outer refraction only exists under
          // Main; both resolve to a legitimate zero rather than the ratio.
          if (actual === null || actual === 0) continue;
          if (key === "inputOuterRefractionAmount" && run.cell.main !== true) continue;
          errors.push({
            error: Math.abs(actual - ratio * short) / (ratio * short),
            key,
            short,
          });
        }
      }
      expect.requireSamples(errors.length, 20, "endpoint checks");
      expect.maxBelow(
        errors,
        (item) => item.error,
        0.001,
        "worst relative endpoint deviation from ratio · shortSide"
      );
    },
  },

  {
    id: "channel-table-covers-every-animating-channel",
    claim:
      "Every glassBackground input that moves during a transition is in the "
      + "channel table. A channel the table does not know is never written by "
      + "the strength controller, so an omission is silent: the input keeps "
      + "whatever the system last left there",
    source: "GlassResearchRoadmap.md — P1.1, baseline-driven curve",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const moving = new Set();
      for (const run of runs) {
        const seen = new Map();
        for (const sample of run.samples ?? []) {
          const inputs = glassBackground(sample)?.inputs ?? {};
          for (const [key, raw] of Object.entries(inputs)) {
            const value = numeric(raw);
            if (value === null) continue;
            if (!seen.has(key)) seen.set(key, new Set());
            seen.get(key).add(value.toFixed(6));
          }
        }
        for (const [key, values] of seen) if (values.size > 1) moving.add(key);
      }

      expect.requireSamples(moving.size, 20, "channels observed moving");
      const known = new Set([...ALL_CHANNELS, "inputBleedDarkenBlend"]);
      const unclassified = [...moving].filter((key) => !known.has(key)).sort();
      expect.equal(
        unclassified.join(",") || "none",
        "none",
        "animating channels missing from the table"
      );
    },
  },
];
