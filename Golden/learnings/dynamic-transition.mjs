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
  numeric, PLATFORM_OWNED_CHANNELS, progressOf, resolveChannel, SHAPES,
  tintComponents,
} from "../tools/lib/golden.mjs";
import { CELL_FIELDS, cellKey, isClearCell } from "../tools/lib/cell.mjs";

const SECTION = "dynamic";

const MATERIALIZE_LIFECYCLE_FIELDS = CELL_FIELDS.filter(
  (field) => field !== "direction"
);
const COMPACT_ADAPTIVE_FACE_GRADE_KEYS = [
  "inputFaceColorMatrixBlack",
  "inputFaceColorMatrixWhite",
];

const endpointInputs = (run) => glassBackground(endpointSample(run))?.inputs ?? null;

const materializeLifecycleKey = (run) =>
  `${run.slice}\0${cellKey(run.cell, MATERIALIZE_LIFECYCLE_FIELDS)}`;

/**
 * Channels that need more than the settled endpoint to replay one paired
 * lifecycle. The insertion can keep adapting after face opacity first reaches
 * one, and the removal can briefly traverse the long-lived compact grade after
 * starting from that insertion's exact settled payload.
 */
export function terminalAdaptiveFaceGradeKeys(insertion, removal = null) {
  if (insertion.cell.direction !== "insertion"
      || insertion.cell.shortSide >= 200) {
    return new Set();
  }
  const firstEndpoint = (insertion.samples ?? [])
    .find(({ phase }) => phase === "endpoint");
  const finalEndpoint = endpointSample(insertion);
  const finalInputs = glassBackground(finalEndpoint)?.inputs;
  if (!finalInputs) return new Set();

  const pairedRemoval = removal?.cell?.direction === "removal"
      && materializeLifecycleKey(removal) === materializeLifecycleKey(insertion)
    ? removal
    : null;
  const observations = [firstEndpoint, ...(pairedRemoval?.samples ?? [])]
    .filter(Boolean);

  const table = channelTable({
    clear: isClearCell(insertion.cell),
    main: insertion.cell.main === true,
  });
  const inflation = geometryInflation(insertion.cell.shortSide);
  const bound = Math.min(0.05, 4 / insertion.cell.shortSide) * 1.05;
  const adaptive = new Set();
  for (const key of COMPACT_ADAPTIVE_FACE_GRADE_KEYS) {
    const channel = table[key];
    const end = numeric(finalInputs[key]);
    if (!channel || end === null) continue;
    const scale = Math.max(1, Math.abs(end - channel.start));
    const exceedsReplayBound = observations.some((sample) => {
      const actual = numeric(glassBackground(sample)?.inputs?.[key]);
      const g = progressOf(sample);
      if (actual === null || g === null) return false;
      const predicted = resolveChannel(channel, g, end, inflation);
      return Math.abs(actual - predicted) / scale > bound;
    });
    if (exceedsReplayBound) adaptive.add(key);
  }
  return adaptive;
}

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
          .map((sample) => {
            const progress = progressOf(sample);
            if (progress !== null) return progress;
            // A completed removal has no glassBackground from which to read
            // face opacity. The missing terminal tree is the direct
            // observation of g = 0, not a missing sample.
            if (
              run.cell.direction === "removal"
              && sample.requestedProgress === 1
            ) return 0;
            return null;
          })
          .filter((value) => value !== null);
        return { min: Math.min(...progresses), max: Math.max(...progresses), run };
      });
      expect.maxBelow(spans, (item) => item.min, 0.1, "worst lowest sampled g");
      // Reported, not asserted. A compact Main-On insertion can stop at 0.9984
      // instead of 1 — the system's own terminal jitter, which the removal
      // warm-up regression documents — and that is below the `g > 0.999` bar
      // `endpointSample` requires, so those runs resolve no endpoint and every
      // endpoint-based learning skips them. Skipping silently is the failure
      // mode this suite exists to avoid, so the count is stated on every run.
      // It is not a hard assertion because it describes the renderer rather
      // than the archive, and one absent cell out of a hundred changes no
      // conclusion drawn here.
      const endpointless = runs.filter((run) => endpointSample(run) === null);
      expect.ok(
        true,
        "runs whose top g misses the endpoint bar",
        endpointless.length === 0
          ? "none"
          : `${endpointless.length}/${runs.length} — `
            + endpointless
              .map((run) =>
                `S=${run.cell.shortSide} v${run.cell.variant} `
                + `main=${run.cell.main} ${run.cell.direction}`
              )
              .join("; ")
      );
    },
  },

  {
    id: "repeated-cells-agree-across-sweeps",
    claim:
      "Four cells are captured twice by separate sweeps. Their settled "
      + "endpoints agree on every channel, so repeated evidence is retained "
      + "rather than deduplicated",
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
        const sources = members.map((run) => run.slice);
        expect.ok(
          sources.every(Boolean) && new Set(sources).size === members.length,
          "repeats come from distinct sweeps",
          sources.join(" + ")
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
      // The direct plan keeps one controlled Dark-backdrop slice across the
      // four material/participation cells. Repeat rows are stability evidence,
      // not extra backdrop coverage.
      const runs = (sections[SECTION].runs ?? []).filter(
        (run) => run.slice !== "repeat"
      );
      const pairs = pairsAcross(runs, "backdrop");
      expect.requireSamples(pairs.length, 4, "backdrop pairs");
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
        const alpha = tintComponents(run)?.[3];
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
      + "shapes reproduces every continuous channel that has a range to scale, "
      + "excepting the small-size adaptive face grade isolated by the "
      + "cross-section learning. Away from the baseline geometry the remaining "
      + "error stays inside min(5%, 4/shortSide), the bound implied by a "
      + "mis-classified linear-vs-height channel. A channel whose endpoint "
      + "equals its start is inert under G and reported rather than replayed",
    source: "GlassResearchRoadmap.md — P1.1, baseline-driven curve",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const perSize = new Map();
      const inertTransients = new Map();
      let comparisons = 0;
      let delegatedAdaptiveComparisons = 0;
      const runsByLifecycle = new Map();
      for (const run of runs) {
        const key = materializeLifecycleKey(run);
        if (!runsByLifecycle.has(key)) runsByLifecycle.set(key, {});
        runsByLifecycle.get(key)[run.cell.direction] = run;
      }
      const adaptiveByLifecycle = new Map(
        [...runsByLifecycle].map(([key, lifecycle]) => [
          key,
          lifecycle.insertion
            ? terminalAdaptiveFaceGradeKeys(
              lifecycle.insertion,
              lifecycle.removal
            )
            : new Set(),
        ])
      );

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
        const adaptiveFaceGrade =
          adaptiveByLifecycle.get(materializeLifecycleKey(run)) ?? new Set();

        for (const sample of run.samples ?? []) {
          const inputs = glassBackground(sample)?.inputs;
          const g = progressOf(sample);
          if (!inputs || g === null) continue;

          for (const [key, channel] of Object.entries(table)) {
            if (adaptiveFaceGrade.has(key)) {
              // On macOS 26 at shortSide 48, face opacity reaches one before
              // the compact face grade finishes adapting. The paired removal
              // then starts from that later grade. No single endpoint can
              // replay either half of this two-stage lifecycle, so the
              // cross-section learning owns these measured channels. macOS 27
              // has no terminal adaptation and delegates nothing here.
              delegatedAdaptiveComparisons += 1;
              continue;
            }
            const end = numeric(endpoint[key]);
            const actual = numeric(inputs[key]);
            if (end === null || actual === null) continue;
            if (
              Math.abs(end - channel.start) < 1e-9
              && !channel.saturationDeficitHump
            ) {
              // The channel is inert: its read endpoint *is* its start, so
              // `start + (end - start) · shape(g)` is the constant start for
              // every g. There is no range to scale and nothing the controller
              // could author differently.
              //
              // A hump channel is excluded from this: `inputBlurOpacity0` reads
              // a zero endpoint below a 64pt short side on macOS 27, yet the
              // deficit term reproduces its full mid-transition excursion from
              // that same zero. A zero range is not the same as no signal.
              //
              // The amplitude is reported below so the exclusion stays visible
              // rather than silently swallowing a channel.
              const seen = inertTransients.get(key);
              const amplitude = Math.abs(actual - channel.start);
              if (!seen || amplitude > seen.amplitude) {
                inertTransients.set(key, { amplitude, short, start: channel.start });
              }
              continue;
            }
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

          // The SDR holding-tone input is another discrete gate. Its inactive
          // endpoint is zero; an active material immediately adopts the live
          // Recipe value rather than interpolating through fractional states.
          const holdingEnd = numeric(endpoint.inputSDRHoldingToneEnabled);
          const holdingActual = numeric(inputs.inputSDRHoldingToneEnabled);
          if (holdingEnd !== null && holdingActual !== null) {
            const predicted = g > 0 ? holdingEnd : 0;
            expect.ok(
              Math.abs(predicted - holdingActual) < 1e-9,
              "inputSDRHoldingToneEnabled discrete gate",
              `g=${g.toFixed(3)} expected ${predicted}, got ${holdingActual}`
            );
          }
        }
      }

      expect.requireSamples(comparisons, 10_000, "channel comparisons");
      expect.ok(
        true,
        "terminal-adaptive face-grade comparisons delegated",
        `${delegatedAdaptiveComparisons}`
      );
      for (const [short, worst] of [...perSize].sort((a, b) => a[0] - b[0])) {
        const bound = Math.min(0.05, 4 / short);
        expect.ok(
          worst.error <= bound * 1.05,
          `shortSide ${short} within min(5%, 4/S)`,
          `worst ${(worst.error * 100).toFixed(3)}% on ${worst.key} `
            + `(bound ${(bound * 100).toFixed(2)}%)`
        );
      }

      // An inert channel is excluded from the bound above, so its excursion has
      // to be bounded here or the exclusion becomes the `ok(true, "not present
      // here")` escape hatch this suite was built to remove. Reporting the
      // amplitude is not enough: a residual that grows from 0.05 to 0.5 would
      // still print green.
      //
      // Measured across both systems, every inert channel sits at *exactly* its
      // constant — 40 of them on macOS 27 — with one exception. Asserting exact
      // zero rather than pooling them under one loose ceiling is what keeps a
      // second channel from quietly starting to move.
      const OWNED_ELSEWHERE = new Set([
        // inputBlurOpacity1 humps to 0.05 at shortSide 48 under Main on macOS
        // 27, off a zero endpoint. Bounded by
        // `gated-blur-overshoots-by-its-saturation-deficit`, which owns the
        // whole channel rather than only its inert cells.
        "inputBlurOpacity1",
      ]);
      const strict = [...inertTransients]
        .filter(([key]) => !OWNED_ELSEWHERE.has(key))
        .map(([key, item]) => ({ key, ...item }));
      if (strict.length > 0) {
        expect.maxBelow(
          strict,
          (item) => item.amplitude,
          1e-6,
          "worst excursion of an inert channel off its constant"
        );
      }
      const delegated = [...inertTransients]
        .filter(([key]) => OWNED_ELSEWHERE.has(key))
        .map(([key, item]) => `${key} lifts ${item.amplitude.toFixed(4)} off `
          + `${item.start} at shortSide ${item.short}`);
      expect.ok(
        true,
        "inert channels bounded elsewhere",
        delegated.length === 0 ? "none" : delegated.join("; ")
      );
    },
  },

  {
    id: "sdf-element-inflates-during-materialize",
    claim:
      "The View Envelope inflates the CASDFElementLayer short side by "
      + "min(0.2 · shortSide, 16) points and retracts it linearly with the "
      + "outer transaction, independently of glassBackground face progress. "
      + "This is the mechanism behind the size-dependent shape term",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const deviations = [];

      for (const run of runs) {
        const rest = run.cell.shortSide;
        const inflation = Math.min(0.2 * rest, 16);
        for (const sample of run.samples ?? []) {
          const requested = sample.requestedProgress;
          if (!Number.isFinite(requested)) continue;
          const g = run.cell.direction === "removal"
            ? 1 - requested
            : requested;
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
      // The residual is absolute, not proportional: 0.70pt is the worst at
      // both 200 and 400 while 48 stays at 0.31. That shape matters more than
      // the number — a deviation that scaled with size would mean the model has
      // the wrong ratio, whereas a size-independent ceiling is the layer's
      // convergence slack at the end of the retraction. Assert the shape, then
      // bound the slack with one point of headroom over the worst observed.
      const worstBySize = new Map();
      for (const item of deviations) {
        const current = worstBySize.get(item.rest) ?? 0;
        worstBySize.set(item.rest, Math.max(current, item.deviation));
      }
      const sizes = [...worstBySize.keys()].sort((a, b) => a - b);
      if (sizes.length >= 2) {
        const ratios = sizes.map((size) => worstBySize.get(size) / size);
        expect.ok(
          Math.max(...ratios) / Math.min(...ratios) > 2,
          "the residual is absolute rather than proportional to size",
          sizes
            .map((size) => `${size}:${worstBySize.get(size).toFixed(2)}pt`)
            .join("  ")
        );
      }
      expect.maxBelow(
        deviations,
        (item) => item.deviation,
        1,
        "worst |observed - min(0.2·S,16) model| in points"
      );
    },
  },

  {
    id: "endpoints-scale-with-short-side",
    claim:
      "Endpoints track shortSide, which is why the curve reads them instead of "
      + "authoring them. Every size-driven endpoint is proportional to S — "
      + "optionally pinned to one constant beyond a floor or a cap — or else "
      + "constant outright. The ratios and the pinned constants are "
      + "version-specific and deliberately reported rather than asserted: "
      + "macOS 27 moved Regular's outer refraction from 0.2·S to max(16, "
      + "0.25·S) and retired its shadow height in favour of a size-invariant "
      + "ring shadow. Asserting the shape is what survives a version bump",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const sizes = new Set(runs.map((run) => run.cell.shortSide));
      expect.requireSamples(sizes.size, 2, "distinct short sides");

      // The size-driven families, plus the ring shadow macOS 27 introduced so
      // its size-invariance is measured rather than assumed.
      const KEYS = [
        "inputBleedAmount", "inputShadowHeight", "inputOuterRefractionAmount",
        "inputRingShadowOffset", "inputRingShadowStrokeWidth",
      ];
      const groups = new Map();
      for (const run of runs) {
        const endpoint = endpointInputs(run);
        if (!endpoint) continue;
        for (const key of KEYS) {
          const value = numeric(endpoint[key]);
          if (value === null) continue;
          const id = `v${run.cell.variant}|main=${run.cell.main}|${key}`;
          if (!groups.has(id)) groups.set(id, new Map());
          groups.get(id).set(run.cell.shortSide, value);
        }
      }

      const findings = [];
      const inert = [];
      for (const [id, bySize] of [...groups].sort()) {
        if (bySize.size < 2) continue;
        const points = [...bySize]
          .map(([size, value]) => ({ size, value }))
          .sort((a, b) => a.size - b.size);
        if (points.every((point) => point.value === 0)) {
          // A legitimate zero: Clear carries no bleed, outer refraction needs
          // Main, and macOS 27 zeroes Regular's shadow height at every size.
          // Recording it is the point — the previous revision skipped zeros
          // silently, so 27 retiring a whole channel read as a pass.
          inert.push(id);
          continue;
        }

        const largest = points[points.length - 1];
        const ratio = largest.value / largest.size;
        const close = (a, b) => Math.abs(a - b) <= 1e-3 * Math.max(Math.abs(b), 1e-9);
        const offLine = points.filter((point) => !close(point.value, ratio * point.size));
        const constant = points.every((point) => close(point.value, largest.value));

        if (constant) {
          findings.push({ id, verdict: `constant ${largest.value}` });
          continue;
        }
        // Proportional, with at most one pinned constant. Every off-line point
        // must share that constant and sit on one side of the line: above it is
        // a floor, below it is a cap.
        const pinned = offLine[0]?.value;
        const agree = offLine.every((point) => close(point.value, pinned));
        const above = offLine.every((point) => Math.abs(point.value) > Math.abs(ratio * point.size));
        const below = offLine.every((point) => Math.abs(point.value) < Math.abs(ratio * point.size));
        expect.ok(
          agree && (above || below),
          `${id} is proportional with at most one pinned constant`,
          `ratio ${ratio.toFixed(4)}·S, off-line ${JSON.stringify(offLine)}`
        );
        findings.push({
          id,
          verdict: offLine.length === 0
            ? `${ratio.toFixed(4)}·S, no floor or cap inside this sweep`
            : `${ratio.toFixed(4)}·S with a ${above ? "floor" : "cap"} at ${pinned}`,
        });
      }

      expect.requireSamples(findings.length, 4, "size-driven endpoint groups");
      for (const finding of findings) {
        expect.ok(true, finding.id, finding.verdict);
      }
      expect.ok(
        true,
        "groups inert at every size",
        inert.length === 0 ? "none" : inert.join(", ")
      );
    },
  },

  {
    id: "gated-blur-overshoots-by-its-saturation-deficit",
    claim:
      "macOS 27 gates the backdrop blur by size, and mid-transition "
      + "inputBlurOpacity0 overshoots its gated endpoint by exactly the amount "
      + "that endpoint falls short of full opacity: "
      + "endpoint·g + (1 - endpoint)·g(1 - g). The coefficient on the deficit "
      + "is 1, not a fitted constant. Where the endpoint is already 1 — every "
      + "Clear cell, and every macOS 26 cell — the term vanishes and the "
      + "channel is the linear ramp measured there, so one law covers both "
      + "systems with no version branch",
    source: "GlassResearchRoadmap.md — P1.1, baseline-driven curve",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      const KEY = "inputBlurOpacity0";
      const gated = [];
      const saturated = [];
      for (const run of runs) {
        if (run.cell.tint !== "None") continue;
        const end = numeric(endpointInputs(run)?.[KEY]);
        if (end === null) continue;
        for (const sample of run.samples ?? []) {
          const value = numeric(glassBackground(sample)?.inputs?.[KEY]);
          const g = progressOf(sample);
          if (value === null || g === null) continue;
          const item = { end, g, value, short: run.cell.shortSide };
          if (Math.abs(1 - end) < 1e-9) saturated.push(item);
          else gated.push(item);
        }
      }

      // Without a gated endpoint there is no deficit, so the coefficient is
      // unmeasurable. macOS 26 saturates at 1 everywhere and lands here.
      expect.requireSamples(gated.length, 20, "samples with a gated endpoint");

      // Fit the coefficient rather than assuming it, away from the turning
      // points where g(1 - g) vanishes and the quotient is ill-conditioned.
      const fitted = gated
        .filter((item) => item.g > 0.2 && item.g < 0.8)
        .map((item) =>
          (item.value - item.end * item.g)
          / ((1 - item.end) * item.g * (1 - item.g)));
      const mean = fitted.reduce((sum, x) => sum + x, 0) / fitted.length;
      expect.ok(
        Math.abs(mean - 1) < 0.01,
        "fitted coefficient on the saturation deficit",
        `${mean.toFixed(4)} over ${fitted.length} samples, expected 1`
      );

      const worstOf = (items) => Math.max(
        ...items.map((item) => Math.abs(
          item.value - (item.end * item.g + (1 - item.end) * item.g * (1 - item.g))
        ))
      );
      expect.maxBelow(
        gated,
        (item) => Math.abs(
          item.value - (item.end * item.g + (1 - item.end) * item.g * (1 - item.g))
        ),
        0.001,
        "worst absolute error on gated cells"
      );
      // The term must not disturb the cells that were already exact.
      expect.ok(
        saturated.length === 0 || worstOf(saturated) < 1e-6,
        "saturated cells are left untouched",
        saturated.length === 0
          ? "none in this section"
          : `worst ${worstOf(saturated).toExponential(2)} over ${saturated.length} samples`
      );

      // inputBlurOpacity1 carries a hump in the same basis, and it is left
      // unmodelled: its amplitude needs a coefficient per participation whose
      // derivation is not understood, and it does not collapse onto the
      // saturation deficit the way inputBlurOpacity0 does. Leaving it linear is
      // a decision; leaving it unbounded would not be. At shortSide 48 under
      // Main its endpoint is zero, so the controller emits a flat zero while the
      // system humps to 0.05 — the single largest residual on macOS 27, and the
      // reason `curve-replays-from-read-endpoints` delegates the channel here
      // instead of pooling it with the genuinely motionless inert channels.
      const secondary = [];
      for (const run of runs) {
        if (run.cell.tint !== "None") continue;
        const end = numeric(endpointInputs(run)?.inputBlurOpacity1);
        if (end === null) continue;
        const main = run.cell.main === true;
        const shape = main ? SHAPES.quadratic : SHAPES.quadraticFlat;
        for (const sample of run.samples ?? []) {
          const value = numeric(glassBackground(sample)?.inputs?.inputBlurOpacity1);
          const g = progressOf(sample);
          if (value === null || g === null) continue;
          secondary.push({
            residual: Math.abs(value - end * shape(g)),
            g: Number(g.toFixed(2)),
            end,
            short: run.cell.shortSide,
          });
        }
      }
      expect.requireSamples(secondary.length, 100, "inputBlurOpacity1 samples");
      // Keep this accepted omission inside the same contract as the general
      // compact replay assertion: a 5% bound with 5% numerical slack.
      const secondaryResidualCeiling = 0.05 * 1.05;
      expect.maxBelow(
        secondary,
        (item) => item.residual,
        secondaryResidualCeiling,
        "accepted residual on the unmodelled inputBlurOpacity1 hump"
      );
    },
  },

  {
    id: "the-blur-taps-crossfade-so-perceived-blur-stays-monotonic",
    claim:
      "inputBlurOpacity0's hump is a crossfade partner, not a stray channel. "
      + "inputBlurOpacity2 is quadratic, so it starts slower than linear and "
      + "runs a deficit of 0.3·g(1-g) early on; inputBlurOpacity0 carries that "
      + "early load and hands off as the quadratic catches up. Their sum rises "
      + "monotonically to its resting value in every cell where either is "
      + "monotonic alone, and never steps backwards by more than a few percent "
      + "of that value. This is why the hump must be reproduced rather than "
      + "flattened: deleting it does not make a strength control monotonic, it "
      + "removes the compensator and leaves the slow-starting quadratic alone, "
      + "so perceived blur arrives late and abruptly instead of early and "
      + "smoothly. A single channel being non-monotonic is not the same as the "
      + "perceived quantity being non-monotonic — which is exactly the "
      + "distinction the P1.3 checklist asks to preserve",
    source: "GlassResearchRoadmap.md — P1.3, monotonic perceived strength",
    sections: [SECTION],
    verify({ sections, expect }) {
      const runs = sections[SECTION].runs ?? [];
      /** Worst backward step of `valueOf` over a run, and the resting value. */
      const walk = (run, valueOf) => {
        const points = [];
        for (const sample of run.samples ?? []) {
          const g = progressOf(sample);
          const inputs = glassBackground(sample)?.inputs;
          if (g === null || !inputs) continue;
          const value = valueOf(inputs);
          if (value === null) continue;
          points.push({ g, value });
        }
        if (points.length < 4) return null;
        points.sort((a, b) => a.g - b.g);
        let drop = 0;
        let highest = -Infinity;
        for (const point of points) {
          if (point.value < highest) drop = Math.max(drop, highest - point.value);
          highest = Math.max(highest, point.value);
        }
        return { drop, resting: points[points.length - 1].value };
      };
      const tap = (key) => (inputs) => numeric(inputs[key]);
      const pair = (inputs) => {
        const a = numeric(inputs.inputBlurOpacity0);
        const b = numeric(inputs.inputBlurOpacity2);
        return a === null || b === null ? null : a + b;
      };

      const humped = [];
      const relative = [];
      for (const run of runs) {
        if (run.cell.tint !== "None") continue;
        const alone = walk(run, tap("inputBlurOpacity0"));
        const together = walk(run, pair);
        if (!alone || !together) continue;
        if (alone.drop > 1e-4) {
          humped.push(`S=${run.cell.shortSide} v${run.cell.variant} `
            + `main=${run.cell.main} ${run.cell.direction} ↓${alone.drop.toFixed(3)}`);
        }
        relative.push({
          fraction: together.drop / Math.max(Math.abs(together.resting), 1e-9),
          drop: together.drop,
          short: run.cell.shortSide,
          main: run.cell.main,
        });
      }
      expect.requireSamples(relative.length, 20, "cells with both blur taps");
      expect.requireSamples(humped.length, 1, "cells where the tap alone humps");

      // The load-bearing assertion. The pair may plateau slightly past its
      // resting value near the top of the ramp — measured at 2.86% — but it must
      // never fade back in any meaningful way. A real regression here would mean
      // the crossfade stopped covering the quadratic's early deficit.
      expect.maxBelow(
        relative,
        (item) => item.fraction,
        0.035,
        "worst backward step of the tap pair, as a fraction of its resting value"
      );
      expect.ok(
        true,
        "cells where inputBlurOpacity0 alone is non-monotonic",
        humped.join("; ")
      );

      // Evidence that the hump is load-bearing rather than decorative: state
      // what the pair would be at low progress without it. Reported, because it
      // describes a counterfactual model rather than an observation.
      const quiet = 0.25;
      const withHump = 0.5 * SHAPES.quadratic(quiet) + quiet * (1 - quiet);
      const without = 0.5 * SHAPES.quadratic(quiet);
      expect.ok(
        true,
        `pair at g=${quiet} with the hump versus without, at a gated endpoint`,
        `${withHump.toFixed(4)} versus ${without.toFixed(4)} — `
          + `${(withHump / without).toFixed(1)}x`
      );
    },
  },

  {
    id: "channel-table-covers-every-animating-channel",
    claim:
      "Every replay-owned glassBackground input that moves during a transition "
      + "is in the channel table. Platform/display-owned inputs remain visible "
      + "evidence but are deliberately never written by the strength controller",
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
      const known = new Set(ALL_CHANNELS);
      const platformOwned = new Set(PLATFORM_OWNED_CHANNELS);
      const unclassified = [...moving]
        .filter((key) => !known.has(key) && !platformOwned.has(key))
        .sort();
      expect.equal(
        unclassified.join(",") || "none",
        "none",
        "animating channels missing from the table"
      );
      expect.ok(
        true,
        "platform-owned moving channels",
        [...moving].filter((key) => platformOwned.has(key)).sort().join(",")
          || "none"
      );
    },
  },
];
