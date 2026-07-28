// Learnings established by the 64-run Materialize environment matrix.
//
// Source: Documentation/GlassResearchRoadmap.md — "P1.1 / Full environment
// matrix and baseline-driven curve".

import {
  endpointFilter, glassBackground, inputValue, isClear, numeric, progressOf,
  shortSideOf, channelTable, resolveChannel, geometryInflation,
} from "../tools/lib/golden.mjs";

const FIXTURE = "materialize-environment-matrix";

/** Groups transitions by every axis except the one under test. */
function groupBy(transitions, keyOf) {
  const groups = new Map();
  for (const transition of transitions) {
    const key = keyOf(transition);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(transition);
  }
  return groups;
}

const axesExcept = (exclude) => (transition) => {
  const context = transition.context;
  const parts = {
    material: isClear(transition) ? "Clear" : "Regular",
    main: context.requestedMain ? "MainOn" : "MainOff",
    appearance: context.requestedAppearance,
    backdrop: context.backdrop,
    tint: context.tint?.label ?? "None",
    direction: transition.direction,
  };
  delete parts[exclude];
  return Object.values(parts).join("|");
};

/** All numeric glassBackground inputs of the settled endpoint. */
function endpointNumbers(transition) {
  const filter = endpointFilter(transition);
  if (!filter) return null;
  const values = {};
  for (const entry of filter.inputs ?? []) {
    const value = numeric(entry.value);
    if (value !== null) values[entry.key] = value;
  }
  return values;
}

export default [
  {
    id: "materialize-matrix-coverage",
    claim:
      "The environment matrix covers all 64 cells with 576 samples, every one "
      + "context-accepted and non-key",
    source: "GlassResearchRoadmap.md — P1.1",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const document = fixtures[FIXTURE];
      const transitions = document.transitions ?? [];
      expect.equal(transitions.length, 64, "transition count");
      const samples = transitions.reduce(
        (sum, t) => sum + (t.samples?.length ?? 0),
        0
      );
      expect.equal(samples, 576, "sample count");

      const keys = new Set(transitions.map(axesExcept(null)));
      expect.equal(keys.size, 64, "distinct dimension cells");

      const rejected = transitions.filter(
        (t) =>
          t.context.actualMain !== t.context.requestedMain || t.context.actualKey
      );
      expect.equal(rejected.length, 0, "context-rejected rows");
    },
  },

  {
    id: "backdrop-does-not-reach-model-state",
    claim:
      "Backdrop luminance changes no model-side value. Adaptation happens in "
      + "the render server via inputBackdropAware and never appears in the model",
    source: "GlassResearchRoadmap.md — P1.1, finding 1",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const groups = groupBy(transitions, axesExcept("backdrop"));
      const differences = [];
      let compared = 0;

      for (const [key, members] of groups) {
        if (members.length !== 2) continue;
        const [a, b] = members.map(endpointNumbers);
        if (!a || !b) continue;
        compared += 1;
        for (const channel of Object.keys(a)) {
          if (!(channel in b)) continue;
          const delta = Math.abs(a[channel] - b[channel]);
          if (delta > 0) differences.push({ key, channel, delta });
        }
      }

      expect.equal(compared, 32, "compared backdrop pairs");
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
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const groups = groupBy(transitions, axesExcept("appearance"));
      let compared = 0;
      const identical = [];

      for (const [key, members] of groups) {
        if (members.length !== 2) continue;
        const [a, b] = members.map(endpointNumbers);
        if (!a || !b) continue;
        compared += 1;
        const changed = Object.keys(a).some(
          (channel) => channel in b && Math.abs(a[channel] - b[channel]) > 1e-9
        );
        if (!changed) identical.push(key);
      }

      expect.equal(compared, 32, "compared appearance pairs");
      // Every appearance-invariant pair must be Clear under Main; anything else
      // would mean an endpoint stopped depending on appearance.
      const unexpected = identical.filter(
        (key) => !(key.startsWith("Clear|MainOn"))
      );
      expect.equal(unexpected.length, 0, "unexpected appearance-invariant pairs");
      expect.equal(identical.length, 8, "Clear+Main pairs invariant on glassBackground");
      expect.equal(
        compared - identical.length,
        24,
        "pairs whose glassBackground endpoints differ"
      );
    },
  },

  {
    id: "topology-is-environment-invariant",
    claim: "No environment axis changes the layer topology of the transition",
    source: "GlassResearchRoadmap.md — P1.1, finding 4",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const signatures = new Map();
      for (const transition of transitions) {
        const key = axesExcept("backdrop")(transition);
        // Layer class sequence, independent of frames and values.
        const signature = (transition.samples ?? [])
          .map((sample) =>
            (sample.snapshot?.model?.layerLines ?? [])
              .map((line) => String(line).trim().split(" ")[0])
              .join(">")
          )
          .join("|");
        if (!signatures.has(key)) signatures.set(key, new Set());
        signatures.get(key).add(signature);
      }
      const mismatched = [...signatures].filter(([, set]) => set.size > 1);
      expect.equal(mismatched.length, 0, "groups with topology mismatch");
    },
  },

  {
    id: "tint-alpha-is-quadratic-in-progress",
    claim:
      "Tint matrix coefficient 18 follows sourceAlpha × g², not a linear ramp. "
      + "A linear model misses by up to 0.25",
    source: "GlassResearchRoadmap.md — P1.1 Tint routing addendum, finding 4",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const pattern = /ColorMatrix4x5\(\[([^\]]+)\];sha256=[0-9a-f]+\)/;
      const residuals = [];

      for (const transition of transitions) {
        const alpha = transition.context.tint?.components?.[3];
        if (!Number.isFinite(alpha)) continue;
        for (const sample of transition.samples ?? []) {
          const model = sample.snapshot?.model;
          const gradient = model?.effects?.find(
            (effect) => effect.effectClass === "CASDFGradientEffect"
          );
          if (!gradient) continue;
          const matrixFilter = model?.filters?.find(
            (f) => f.path === gradient.path && f.name === "vibrantColorMatrix"
          );
          const raw = inputValue(matrixFilter?.inputs, "inputColorMatrix");
          if (typeof raw !== "string") continue;
          const match = raw.match(pattern);
          if (!match) continue;
          const coefficients = match[1].split(",").map(Number);
          if (coefficients.length !== 20) continue;
          const g = progressOf(sample.snapshot);
          if (g === null) continue;
          residuals.push({
            residual: Math.abs(coefficients[18] - alpha * g * g),
            g,
            alpha,
          });
        }
      }

      expect.ok(residuals.length >= 256, "tinted samples", `${residuals.length}`);
      expect.maxBelow(
        residuals,
        (item) => item.residual,
        1e-4,
        "worst |coefficient18 - a·g²|"
      );
    },
  },

  {
    id: "curve-replays-from-read-endpoints",
    claim:
      "Reading endpoints from the Recipe and applying the five dimensionless "
      + "shapes reproduces the system transition at the baseline geometry",
    source: "GlassResearchRoadmap.md — P1.1, baseline-driven curve",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const transitions = fixtures[FIXTURE].transitions ?? [];
      const errors = [];

      for (const transition of transitions) {
        if ((transition.context.tint?.label ?? "None") !== "None") continue;
        const endpoint = endpointFilter(transition);
        if (!endpoint) continue;
        const clear = isClear(transition);
        const main = transition.context.requestedMain === true;
        const light = transition.context.requestedAppearance === "Light";
        const inflation = geometryInflation(shortSideOf(transition.context));
        const table = channelTable({ clear, main });

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
            errors.push({
              error: Math.abs(actual - predicted) / scale,
              key,
              g: Number(g.toFixed(3)),
            });
          }

          // The one discrete edge: Clear in DarkAqua steps at the midpoint.
          const end = numeric(inputValue(endpoint.inputs, "inputBleedDarkenBlend"));
          const actual = numeric(inputValue(filter.inputs, "inputBleedDarkenBlend"));
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

      expect.ok(errors.length > 10000, "channel comparisons", `${errors.length}`);
      expect.maxBelow(
        errors,
        (item) => item.error,
        0.0011,
        "worst normalized replay error"
      );
    },
  },
];
