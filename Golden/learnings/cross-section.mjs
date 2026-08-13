// Learnings that hold the static and dynamic sections against each other.
//
// These are the reason the two sections share one cell coordinate. A claim like
// "strength 1 reproduces the source Recipe" spans both: the endpoint comes from
// the transition, the Recipe from the static sweep, and nothing checks that
// they agree unless something pairs them.

import { endpointInputs, numeric } from "../tools/lib/golden.mjs";
import { compatible, sharedKey } from "../tools/lib/cell.mjs";

const STATIC = "static-scalar";
const DYNAMIC = "dynamic";

/** The geometry the strength control is measured and shipped at. */
const REFERENCE_SHORT_SIDE = 200;

/**
 * Pairs each settled insertion endpoint with the static Recipe row addressing
 * the same cell. Subdued is null on dynamic rows and appearance was historically
 * null on static ones, so pairing goes through `compatible` rather than an exact
 * key: a null axis cannot contradict anything.
 */
function pairs(sections) {
  const staticRows = (sections[STATIC].rows ?? []).filter(
    (row) => row.cell.key !== true && row.cell.subvariant === null
  );
  const byShared = new Map();
  for (const row of staticRows) {
    const key = sharedKey(row.cell);
    if (!byShared.has(key)) byShared.set(key, []);
    byShared.get(key).push(row);
  }

  const found = [];
  for (const run of sections[DYNAMIC].runs ?? []) {
    if (run.cell.direction !== "insertion") continue;
    if (run.cell.tint !== "None") continue;
    const candidates = byShared.get(sharedKey(run.cell)) ?? [];
    const match = candidates.find((row) => compatible(row.cell, run.cell));
    const endpoint = endpointInputs(run);
    if (!match || !endpoint) continue;
    found.push({ run, row: match, endpoint });
  }
  return found;
}

/** Channels where the two sections disagree by more than `tolerance`. */
function divergence({ row, endpoint }, tolerance) {
  const channels = [];
  for (const [key, staticValue] of Object.entries(row.inputs ?? {})) {
    const dynamicValue = numeric(endpoint[key]);
    if (typeof staticValue !== "number" || dynamicValue === null) continue;
    const scale = Math.max(1e-6, Math.abs(staticValue));
    if (Math.abs(dynamicValue - staticValue) / scale > tolerance) {
      channels.push({ key, staticValue, dynamicValue });
    }
  }
  return channels;
}

export default [
  {
    id: "materialized-endpoint-matches-the-static-recipe-at-the-reference-size",
    claim:
      "At the reference geometry a glass that has completed a Materialize In "
      + "resolves the same Recipe as one created already presented. This is what "
      + "lets the strength control read its baseline from whatever tree it is "
      + "handed: if the two disagreed, the endpoint would depend on the view's "
      + "history rather than its context",
    source: "GlassResearchRoadmap.md — P1 exit criteria, strength 1 reproduces the Recipe",
    sections: [STATIC, DYNAMIC],
    verify({ sections, expect }) {
      const reference = pairs(sections).filter(
        (pair) => pair.run.cell.shortSide === REFERENCE_SHORT_SIDE
      );
      expect.requireSamples(
        reference.length,
        4,
        `pairs at shortSide ${REFERENCE_SHORT_SIDE}`
      );

      const offenders = [];
      for (const pair of reference) {
        for (const channel of divergence(pair, 0.01)) {
          offenders.push(
            `v${pair.run.cell.variant} main=${pair.run.cell.main} `
            + `${pair.run.cell.appearance} ${channel.key} `
            + `${channel.staticValue} vs ${channel.dynamicValue}`
          );
        }
      }
      expect.equal(
        offenders.slice(0, 3).join("; ") || "none",
        "none",
        "channels diverging at the reference geometry"
      );
    },
  },

  {
    id: "the-two-endpoints-diverge-below-a-size-threshold",
    claim:
      "Away from the reference geometry the two endpoints stop agreeing. A "
      + "small glass uses a different face grade at the Materialize animation "
      + "endpoint than its long-lived static Recipe. Face opacity reaches one "
      + "before that compact grade finishes adapting, and the paired removal "
      + "starts from the later settled grade, so a single baseline cannot "
      + "reproduce the whole small-size lifecycle. The diverging sizes and channels are "
      + "reported rather than asserted: which ones they are is a measured "
      + "property of the release, but that some threshold exists is what a "
      + "consumer has to know",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    sections: [STATIC, DYNAMIC],
    verify({ sections, expect }) {
      const all = pairs(sections);
      const sizes = [...new Set(all.map((pair) => pair.run.cell.shortSide))]
        .sort((a, b) => a - b);
      expect.requireSamples(sizes.length, 2, "distinct short sides paired");

      const perSize = new Map();
      for (const pair of all) {
        const size = pair.run.cell.shortSide;
        if (!perSize.has(size)) perSize.set(size, new Set());
        for (const channel of divergence(pair, 0.01)) {
          perSize.get(size).add(channel.key);
        }
      }

      for (const size of sizes) {
        const channels = [...(perSize.get(size) ?? [])].sort();
        expect.ok(
          true,
          `shortSide ${size}`,
          channels.length === 0
            ? "endpoints agree"
            : `${channels.length} diverging: ${channels.join(", ")}`
        );
      }

      // The threshold has to be monotone to be usable. A consumer can only act
      // on "above size X the two agree"; agreement that came and went with size
      // would mean the divergence is not a geometry effect at all.
      const agreeing = sizes.filter(
        (size) => (perSize.get(size)?.size ?? 0) === 0
      );
      const diverging = sizes.filter(
        (size) => (perSize.get(size)?.size ?? 0) > 0
      );
      expect.requireSamples(agreeing.length, 1, "sizes whose endpoints agree");
      expect.requireSamples(diverging.length, 1, "sizes whose endpoints diverge");
      expect.ok(
        Math.max(...diverging) < Math.min(...agreeing),
        "divergence is confined to the small end",
        `diverges at ${diverging.join(",")}, agrees at ${agreeing.join(",")}`
      );
    },
  },
];
