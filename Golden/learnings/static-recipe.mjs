// Static Recipe resolution, from the scalar shader-input sweep.
//
// Source: Documentation/AppKitGlassReverseEngineering.md — "Geometry input is
// the shortest side".
//
// Two of these deliberately report unverifiable rather than pass. The claims
// are accepted — they came from dedicated probes — but the archived sweep does
// not contain the axis needed to re-derive them, and a green tick for a check
// that never ran is worse than no check at all.

const SECTION = "static-scalar";

const baseRows = (rows) =>
  rows.filter((row) => !row.cell.subvariant && row.cell.subdued === false);

const regularMain = (rows) =>
  baseRows(rows).filter(
    (row) => row.cell.variant === 1 && row.cell.main === true
  );

export default [
  {
    id: "corner-radius-does-not-reach-the-shader",
    claim:
      "Corner radius changes no numeric shader input. It drives SDF/path "
      + "geometry only, so the strength curve can ignore it entirely",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const radii = sections[SECTION].axes.values.cornerRadius ?? [];
      if (radii.length < 2) {
        expect.unverifiable(
          `no cornerRadius axis — every row is radius ${radii.join(",")}. `
          + "The accepted claim came from a probe that was never archived; "
          + "the exporter has to sweep this before it can be re-derived"
        );
      }
      const rows = baseRows(sections[SECTION].rows ?? []);
      const groups = new Map();
      for (const row of rows) {
        const key = [row.cell.variant, row.cell.main, row.cell.shortSide].join("|");
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
      }
      const differing = [];
      for (const [key, members] of groups) {
        const [reference, ...rest] = members;
        for (const other of rest) {
          for (const [input, value] of Object.entries(reference.inputs ?? {})) {
            const candidate = other.inputs?.[input];
            if (typeof value !== "number" || typeof candidate !== "number") continue;
            if (Math.abs(value - candidate) > 1e-6) {
              differing.push({ key, input, value, candidate });
            }
          }
        }
      }
      expect.equal(differing.length, 0, "inputs differing by corner radius only");
    },
  },

  {
    id: "short-side-is-the-only-geometry-variable",
    claim:
      "Width and height reach the Recipe only through min(width, height). "
      + "Rows sharing a short side resolve identical shader inputs",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = baseRows(sections[SECTION].rows ?? []);
      const groups = new Map();
      for (const row of rows) {
        const key = [row.cell.variant, row.cell.main, row.cell.shortSide].join("|");
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
      }
      // The claim needs two rows that share a short side while differing in
      // width or height. The sweep is 480 × {24, 200, 600}, so every short side
      // occurs exactly once and no such pair exists.
      const testable = [...groups.values()].filter((members) => {
        const shapes = new Set(
          members.map((row) => `${row.cell.width}x${row.cell.height}`)
        );
        return shapes.size > 1;
      });
      if (testable.length === 0) {
        expect.unverifiable(
          "no two rows share a short side with different width/height — the "
          + "sweep varies height at a fixed width 480. One transposed size pair "
          + "(200×480 beside 480×200) would make this decidable"
        );
      }
      const differing = [];
      for (const members of testable) {
        const [reference, ...rest] = members;
        for (const other of rest) {
          for (const [input, value] of Object.entries(reference.inputs ?? {})) {
            const candidate = other.inputs?.[input];
            if (typeof value !== "number" || typeof candidate !== "number") continue;
            if (Math.abs(value - candidate) > 1e-6) differing.push({ input });
          }
        }
      }
      expect.equal(differing.length, 0, "inputs differing at equal shortSide");
    },
  },

  {
    id: "size-scaled-inputs-follow-simple-ratios",
    claim:
      "Size-driven inputs are proportional to shortSide, some with a cap. "
      + "Bleed 0.35·S and shadow height 0.4·S hold uncapped across the sweep",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = regularMain(sections[SECTION].rows ?? []);
      const ratios = { inputBleedAmount: 0.35, inputShadowHeight: 0.4 };
      const errors = [];
      for (const row of rows) {
        const short = row.cell.shortSide;
        for (const [key, ratio] of Object.entries(ratios)) {
          const actual = row.inputs?.[key];
          if (typeof actual !== "number" || actual === 0) continue;
          errors.push({
            error: Math.abs(actual - ratio * short) / (ratio * short),
            key,
            short,
          });
        }
      }
      expect.requireSamples(errors.length, 3, "size-scaled samples");
      expect.maxBelow(
        errors,
        (item) => item.error,
        0.001,
        "worst relative deviation from ratio · shortSide"
      );
    },
  },

  {
    id: "inner-refraction-caps-above-a-threshold",
    claim:
      "Inner refraction is proportional below a cap and pinned above it. The "
      + "ratio is version-specific and deliberately not asserted: macOS 26.6 "
      + "resolves -0.8·S and macOS 27.0 resolves -0.5·S, visible only below the "
      + "cap. Asserting the shape rather than the value is what lets this "
      + "learning survive a version bump",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = regularMain(sections[SECTION].rows ?? []);
      const bySize = new Map(rows.map((row) => [row.cell.shortSide, row.inputs ?? {}]));
      const sizes = [...bySize.keys()].sort((a, b) => a - b);
      expect.requireSamples(sizes.length, 2, "distinct short sides");

      for (const key of ["inputInnerRefractionAmount", "inputInnerRefractionHeight"]) {
        const samples = sizes
          .map((size) => ({ size, value: bySize.get(size)?.[key] }))
          .filter((sample) => typeof sample.value === "number");
        if (samples.length < 2) continue;

        const magnitudes = samples.map((sample) => Math.abs(sample.value));
        expect.ok(
          magnitudes.every((v, i) => i === 0 || v >= magnitudes[i - 1] - 1e-9),
          `${key} magnitude is non-decreasing in size`
        );

        const smallest = samples[0];
        const largest = samples[samples.length - 1];
        const atSmallest = smallest.value / smallest.size;
        const atLargest = largest.value / largest.size;
        expect.ok(
          Math.abs(atLargest) < Math.abs(atSmallest) - 1e-9,
          `${key} ratio collapses with size, i.e. it is capped`,
          `${atSmallest.toFixed(4)} at ${smallest.size} -> `
            + `${atLargest.toFixed(4)} at ${largest.size}`
        );
      }
    },
  },
];
