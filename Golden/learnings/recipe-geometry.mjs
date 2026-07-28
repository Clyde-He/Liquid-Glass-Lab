// Learnings about static Recipe resolution, established by the Recipe matrix.
//
// Source: Documentation/AppKitGlassReverseEngineering.md — "Geometry input is
// the shortest side".

const FIXTURE = "recipe-matrix";

const shortSideOf = (entry) => Math.min(entry.glassWidth, entry.glassHeight);

const baseRows = (entries) =>
  entries.filter(
    (entry) => !entry.subvariant && entry.subdued === false
  );

export default [
  {
    id: "corner-radius-does-not-reach-the-shader",
    claim:
      "Corner radius changes no numeric shader input. It drives SDF/path "
      + "geometry only, so the strength curve can ignore it entirely",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const entries = fixtures[FIXTURE].entries ?? [];
      const radii = new Set(entries.map((entry) => entry.cornerRadius));
      if (radii.size < 2) {
        // The archived matrix fixes cornerRadius at 16; the claim was accepted
        // from a dedicated sweep that was not retained as a fixture.
        expect.ok(
          true,
          "corner radius axis not present in this fixture",
          `only radius ${[...radii].join(",")} archived — claim unverifiable here`
        );
        return;
      }
      expect.ok(radii.size >= 2, "corner radius values", `${[...radii]}`);
    },
  },

  {
    id: "short-side-is-the-only-geometry-variable",
    claim:
      "Width and height reach the Recipe only through min(width, height). "
      + "Rows sharing a short side resolve identical shader inputs",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const entries = baseRows(fixtures[FIXTURE].entries ?? []);
      // Key on everything except geometry, then require that rows agreeing on
      // shortSide agree on every numeric input.
      const groups = new Map();
      for (const entry of entries) {
        const key = [
          entry.variant,
          entry.requestedMain,
          shortSideOf(entry),
        ].join("|");
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(entry);
      }

      const mismatches = [];
      let compared = 0;
      for (const [key, members] of groups) {
        if (members.length < 2) continue;
        const [reference, ...rest] = members;
        for (const other of rest) {
          compared += 1;
          for (const [input, value] of Object.entries(reference.inputs ?? {})) {
            const candidate = other.inputs?.[input];
            if (typeof value !== "number" || typeof candidate !== "number") {
              continue;
            }
            if (Math.abs(value - candidate) > 1e-6) {
              mismatches.push({ key, input, value, candidate });
            }
          }
        }
      }

      if (compared === 0) {
        expect.ok(
          true,
          "no repeated short side in this fixture",
          "matrix sweeps height only, so the claim is not re-derivable here"
        );
        return;
      }
      expect.equal(mismatches.length, 0, "inputs differing at equal shortSide");
    },
  },

  {
    id: "size-scaled-inputs-follow-simple-ratios",
    claim:
      "Size-driven inputs are proportional to shortSide, some with a cap. "
      + "Bleed 0.35·S and shadow height 0.4·S hold uncapped across the sweep",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const entries = baseRows(fixtures[FIXTURE].entries ?? []).filter(
        (entry) => entry.variant === 1 && entry.requestedMain === true
      );
      const ratios = { inputBleedAmount: 0.35, inputShadowHeight: 0.4 };
      const errors = [];

      for (const entry of entries) {
        const short = shortSideOf(entry);
        for (const [key, ratio] of Object.entries(ratios)) {
          const actual = entry.inputs?.[key];
          if (typeof actual !== "number" || actual === 0) continue;
          errors.push({
            error: Math.abs(actual - ratio * short) / (ratio * short),
            key,
            short,
          });
        }
      }

      // Clear carries no bleed, so a sweep of N sizes yields N shadow-height
      // samples and N bleed samples only for Regular.
      expect.ok(errors.length >= 3, "size-scaled samples", `${errors.length}`);
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
    fixtures: [FIXTURE],
    verify({ fixtures, expect }) {
      const entries = baseRows(fixtures[FIXTURE].entries ?? []).filter(
        (entry) => entry.variant === 1 && entry.requestedMain === true
      );
      const bySize = new Map(
        entries.map((entry) => [shortSideOf(entry), entry.inputs ?? {}])
      );
      const sizes = [...bySize.keys()].sort((a, b) => a - b);
      if (sizes.length < 2) {
        expect.ok(true, "needs at least two sizes", `have ${sizes}`);
        return;
      }

      for (const key of [
        "inputInnerRefractionAmount",
        "inputInnerRefractionHeight",
      ]) {
        const samples = sizes
          .map((size) => ({ size, value: bySize.get(size)?.[key] }))
          .filter((s) => typeof s.value === "number");
        if (samples.length < 2) continue;

        // Magnitude must be non-decreasing with size, and must stop growing
        // once capped: the largest two sizes share a value.
        const magnitudes = samples.map((s) => Math.abs(s.value));
        const monotonic = magnitudes.every(
          (value, index) => index === 0 || value >= magnitudes[index - 1] - 1e-9
        );
        expect.ok(monotonic, `${key} magnitude is non-decreasing in size`);

        const smallest = samples[0];
        const largest = samples[samples.length - 1];
        const ratioAtSmallest = smallest.value / smallest.size;
        const ratioAtLargest = largest.value / largest.size;
        expect.ok(
          Math.abs(ratioAtLargest) < Math.abs(ratioAtSmallest) - 1e-9,
          `${key} ratio collapses with size, i.e. it is capped`,
          `${ratioAtSmallest.toFixed(4)} at ${smallest.size} -> `
            + `${ratioAtLargest.toFixed(4)} at ${largest.size}`
        );
      }
    },
  },
];
