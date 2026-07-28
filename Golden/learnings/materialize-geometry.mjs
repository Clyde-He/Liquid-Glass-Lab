// Learnings established by the shortSide 48/200/400 geometry sweep.
//
// Source: Documentation/GlassResearchRoadmap.md — "P1.1 / Geometry spot check".

import {
  endpointFilter, glassBackground, inputValue, isClear, numeric, progressOf,
  shortSideOf, channelTable, resolveChannel, geometryInflation,
} from "../tools/lib/golden.mjs";

const FIXTURE = "materialize-geometry-sweep";

export default [
  {
    id: "materialize-geometry-coverage",
    claim: "The geometry sweep covers 12 runs across shortSide 48, 200, and 400",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const document = fixtures[FIXTURE];
      const transitions = document.transitions ?? [];
      expect.equal(transitions.length, 12, "transition count");
      const sizes = new Set(
        transitions.map((t) => shortSideOf(t.context))
      );
      expect.equal([...sizes].sort((a, b) => a - b).join(","), "48,200,400",
        "sampled shortSide values");
      const rejected = transitions.filter(
        (t) =>
          t.context.actualMain !== t.context.requestedMain || t.context.actualKey
      );
      expect.equal(rejected.length, 0, "context-rejected rows");
    },
  },

  {
    id: "sdf-element-inflates-during-materialize",
    claim:
      "Materialize inflates the CASDFElementLayer short side by "
      + "min(0.2 · shortSide, 16) points and retracts it linearly with g. This "
      + "is the mechanism behind the size-dependent shape term",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const deviations = [];

      for (const transition of transitions) {
        const rest = shortSideOf(transition.context);
        const inflation = Math.min(0.2 * rest, 16);
        for (const sample of transition.samples ?? []) {
          const g = progressOf(sample.snapshot);
          if (g === null) continue;
          let widest = null;
          for (const line of sample.snapshot?.model?.layerLines ?? []) {
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

      expect.ok(deviations.length >= 18, "observed element frames",
        `${deviations.length}`);
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
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const ratios = {
        inputBleedAmount: 0.35,
        inputShadowHeight: 0.4,
        inputOuterRefractionAmount: 0.2,
      };
      const errors = [];

      for (const transition of transitions) {
        const filter = endpointFilter(transition);
        if (!filter) continue;
        const short = shortSideOf(transition.context);
        const main = transition.context.requestedMain === true;
        for (const [key, ratio] of Object.entries(ratios)) {
          const actual = numeric(inputValue(filter.inputs, key));
          if (actual === null) continue;
          // Clear carries no bleed, and outer refraction only exists under
          // Main; both resolve to a legitimate zero rather than the ratio.
          if (actual === 0) continue;
          if (key === "inputOuterRefractionAmount" && !main) continue;
          errors.push({
            error: Math.abs(actual - ratio * short) / (ratio * short),
            key,
            short,
            actual,
          });
        }
      }

      expect.ok(errors.length >= 20, "endpoint checks", `${errors.length}`);
      expect.maxBelow(
        errors,
        (item) => item.error,
        0.001,
        "worst relative endpoint deviation from ratio · shortSide"
      );
    },
  },

  {
    id: "curve-replay-error-is-bounded-by-size",
    claim:
      "Away from the baseline geometry the replay error stays within "
      + "min(5%, 4/shortSide), the bound implied by a mis-classified "
      + "linear-vs-height channel",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const perSize = new Map();

      for (const transition of transitions) {
        const endpoint = endpointFilter(transition);
        if (!endpoint) continue;
        const short = shortSideOf(transition.context);
        const inflation = geometryInflation(short);
        const table = channelTable({
          clear: isClear(transition),
          main: transition.context.requestedMain === true,
        });

        for (const sample of transition.samples ?? []) {
          const filter = glassBackground(sample.snapshot);
          const g = progressOf(sample.snapshot);
          if (!filter || g === null) continue;
          for (const [key, channel] of Object.entries(table)) {
            const end = numeric(inputValue(endpoint.inputs, key));
            const actual = numeric(inputValue(filter.inputs, key));
            if (end === null || actual === null) continue;
            const predicted = resolveChannel(channel, g, end, inflation);
            const scale = Math.max(1, Math.abs(end - channel.start));
            const error = Math.abs(actual - predicted) / scale;
            const worst = perSize.get(short);
            if (!worst || error > worst.error) {
              perSize.set(short, { error, key, g: Number(g.toFixed(3)) });
            }
          }
        }
      }

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
];
