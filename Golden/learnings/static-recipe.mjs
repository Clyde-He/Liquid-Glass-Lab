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
  rows.filter(
    (row) =>
      !row.cell.subvariant
      && row.cell.subdued === false
      && row.cell.key !== true
  );

const regularMain = (rows) =>
  baseRows(rows).filter(
    (row) => row.cell.variant === 1 && row.cell.main === true
  );

const payloadSignature = (row) =>
  ["inputs", "highlight", "geometry", "colors", "points", "strings"]
    .map((field) =>
      `${field}:${JSON.stringify(Object.entries(row[field] ?? {}).sort())}`
    )
    .join("|");

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
        // Appearance belongs in the key. It moves resolved values, so leaving
        // it out puts Light and Dark rows in one group and reports their real
        // difference as a corner-radius or aspect-ratio effect.
        const key = [
          row.cell.variant, row.cell.main, row.cell.appearance,
          row.cell.shortSide,
        ].join("|");
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
        // Appearance belongs in the key. It moves resolved values, so leaving
        // it out puts Light and Dark rows in one group and reports their real
        // difference as a corner-radius or aspect-ratio effect.
        const key = [
          row.cell.variant, row.cell.main, row.cell.appearance,
          row.cell.shortSide,
        ].join("|");
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
    id: "real-key-participation-selects-the-active-recipe",
    claim:
      "A Panel that is genuinely key without being main resolves the same "
      + "Regular/Clear Recipe payload as Main participation",
    source: "Golden/CAPTURE-SPEC.md — static-scalar real key slice",
    sections: [SECTION],
    verify({ sections, expect }) {
      const document = sections[SECTION];
      const keyValues = document.axes.values.key ?? [];
      if (!keyValues.includes(true)) {
        expect.unverifiable(
          "no real-key slice — capture with the direct Golden exporter"
        );
      }

      const rows = document.rows ?? [];
      const keyRows = rows.filter((row) => row.cell.key === true);
      expect.equal(keyRows.length, 4, "real-key rows");
      const missing = [];
      const differing = [];
      for (const keyRow of keyRows) {
        const cell = keyRow.cell;
        const mainRow = rows.find((row) =>
          row.cell.variant === cell.variant
          && row.cell.subvariant === cell.subvariant
          && row.cell.main === true
          && row.cell.key === false
          && row.cell.subdued === cell.subdued
          && row.cell.appearance === cell.appearance
          && row.cell.backdrop === cell.backdrop
          && row.cell.tint === cell.tint
          && row.cell.width === cell.width
          && row.cell.height === cell.height
          && row.cell.cornerRadius === cell.cornerRadius
          && row.cell.host === cell.host
        );
        if (!mainRow) {
          missing.push(`variant ${cell.variant} subdued ${cell.subdued}`);
          continue;
        }
        if (keyRow.participation !== "key") {
          differing.push(`variant ${cell.variant}: participation=${keyRow.participation}`);
        }
        if (payloadSignature(keyRow) !== payloadSignature(mainRow)) {
          differing.push(`variant ${cell.variant}: payload`);
        }
      }
      expect.equal(missing.length, 0, "key cells missing a Main counterpart");
      expect.equal(differing.length, 0, "key/Main payload differences");
    },
  },

  {
    id: "size-scaled-inputs-follow-simple-ratios",
    claim:
      "Size-driven inputs are proportional to shortSide, some with a cap. "
      + "Bleed 0.35·S holds uncapped across the sweep on both systems; shadow "
      + "height holds 0.4·S on macOS 26 and is retired to a flat zero on "
      + "macOS 27, where a size-invariant ring shadow replaces it",
    source: "AppKitGlassReverseEngineering.md — Geometry input is the shortest side",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = regularMain(sections[SECTION].rows ?? []);
      const ratios = { inputBleedAmount: 0.35, inputShadowHeight: 0.4 };
      const errors = [];
      const zeroed = new Map();
      for (const row of rows) {
        const short = row.cell.shortSide;
        for (const [key, ratio] of Object.entries(ratios)) {
          const actual = row.inputs?.[key];
          if (typeof actual !== "number") continue;
          if (actual === 0) {
            // Counted, not skipped. The previous revision dropped zeros
            // silently, so macOS 27 retiring shadow height outright still read
            // as a pass on a claim nothing had checked.
            zeroed.set(key, (zeroed.get(key) ?? 0) + 1);
            continue;
          }
          errors.push({
            error: Math.abs(actual - ratio * short) / (ratio * short),
            key,
            short,
          });
        }
      }
      // A channel is either proportional at every size or inert at every size.
      // Half of each would mean the ratio has a floor this sweep would then
      // have to locate, and none of these do.
      for (const [key, count] of [...zeroed].sort()) {
        const scaled = errors.filter((item) => item.key === key).length;
        expect.equal(
          scaled === 0 ? "inert everywhere" : `mixed: ${scaled} scaled, ${count} zero`,
          "inert everywhere",
          `${key} resolves zero on ${count} rows`
        );
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

  {
    id: "appearance-moves-static-recipe-values",
    claim:
      "Appearance is a Recipe input on the static side too, not only during a "
      + "transition. It moves resolved values for a majority of Variants while "
      + "changing none of the pass inventory, which is why a strength control "
      + "can read one baseline per context and ignore appearance entirely — but "
      + "also why a capture that pins appearance to one value answers "
      + "\"which Variants follow appearance\" for only half the vocabulary",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const appearances = sections[SECTION].axes.values.appearance ?? [];
      if (appearances.length < 2) {
        expect.unverifiable(
          `only appearance ${appearances.join(",") || "none"} captured — the `
          + "static core has to sweep both controlled appearances before this "
          + "can be re-derived"
        );
      }

      // Pair rows that differ in appearance and nothing else.
      const groups = new Map();
      for (const row of sections[SECTION].rows ?? []) {
        if (row.slice !== "core") continue;
        const key = [
          row.cell.variant, row.cell.subvariant, row.cell.main,
          row.cell.key, row.cell.subdued, row.cell.width, row.cell.height,
          row.cell.cornerRadius, row.cell.host,
        ].join("|");
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(row);
      }

      const movedVariants = new Set();
      const movedChannels = new Set();
      let compared = 0;
      for (const members of groups.values()) {
        if (members.length !== 2) continue;
        compared += 1;
        const [a, b] = members;
        for (const [channel, value] of Object.entries(a.inputs ?? {})) {
          const other = b.inputs?.[channel];
          if (typeof value !== "number" || typeof other !== "number") continue;
          const scale = Math.max(1e-6, Math.abs(value));
          if (Math.abs(value - other) / scale > 0.001) {
            movedVariants.add(a.cell.variant);
            movedChannels.add(channel);
          }
        }
      }

      expect.requireSamples(compared, 84, "appearance pairs compared");
      expect.ok(
        movedVariants.size > 0,
        "appearance moves resolved values",
        `${movedVariants.size} of 21 Variants, ${movedChannels.size} channels`
      );
      // Reported, never asserted: which Variants and channels follow appearance
      // is a measured property of the release.
      expect.ok(
        true,
        "Variants following appearance",
        [...movedVariants].sort((x, y) => x - y).join(",")
      );
    },
  },
];
