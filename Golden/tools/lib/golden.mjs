// Shared loading and assertion helpers for the learning suite.
//
// A "learning" is one accepted finding from Documentation/, expressed as an
// executable assertion over archived fixtures. The point is that re-validating
// the whole body of knowledge on a new OS becomes one command instead of a
// manual reread.

import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

// .../Golden/tools/lib/golden.mjs -> .../Golden
export const goldenDirectory = path.dirname(
  path.dirname(path.dirname(fileURLToPath(import.meta.url)))
);

/** OS directories present in the archive, e.g. ["macOS-26", "macOS-27"]. */
export async function osDirectories() {
  const entries = await readdir(goldenDirectory, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && /^macOS-/.test(entry.name))
    .map((entry) => entry.name)
    .sort();
}

export async function readManifest(osDirectory) {
  const raw = await readFile(
    path.join(goldenDirectory, osDirectory, "manifest.json"),
    "utf8"
  );
  return JSON.parse(raw);
}

/**
 * Loads fixtures by manifest id, caching per run. Returns null for a fixture
 * this OS directory does not have, which is how a learning reports "not
 * applicable here" rather than failing.
 */
export function makeFixtureLoader(osDirectory, manifest) {
  const cache = new Map();
  return async function fixture(id) {
    if (cache.has(id)) return cache.get(id);
    const entry = (manifest.fixtures ?? []).find((item) => item.id === id);
    if (!entry) {
      cache.set(id, null);
      return null;
    }
    const raw = await readFile(
      path.join(goldenDirectory, osDirectory, entry.file),
      "utf8"
    );
    const parsed = JSON.parse(raw);
    cache.set(id, parsed);
    return parsed;
  };
}

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// MARK: - Assertions

export class LearningFailure extends Error {}

/** Every assertion records what it checked so a pass is still auditable. */
export function makeExpect(observations) {
  function record(label, detail) {
    observations.push(`${label}: ${detail}`);
  }
  return {
    ok(condition, label, detail = "") {
      if (!condition) {
        throw new LearningFailure(`${label}${detail ? ` — ${detail}` : ""}`);
      }
      record(label, detail || "ok");
    },
    equal(actual, expected, label) {
      if (actual !== expected) {
        throw new LearningFailure(
          `${label} — expected ${expected}, got ${actual}`
        );
      }
      record(label, `${actual}`);
    },
    /** Absolute tolerance; use for values whose scale is known. */
    near(actual, expected, tolerance, label) {
      const delta = Math.abs(actual - expected);
      if (!(delta <= tolerance)) {
        throw new LearningFailure(
          `${label} — |${actual} - ${expected}| = ${delta.toPrecision(4)} `
            + `exceeds ${tolerance}`
        );
      }
      record(label, `Δ=${delta.toPrecision(3)} ≤ ${tolerance}`);
    },
    /** Worst-case over a collection, reported with the offending item. */
    maxBelow(items, valueOf, limit, label) {
      let worst = null;
      for (const item of items) {
        const value = valueOf(item);
        if (!Number.isFinite(value)) continue;
        if (worst === null || value > worst.value) worst = { value, item };
      }
      if (worst === null) {
        throw new LearningFailure(`${label} — nothing to compare`);
      }
      if (!(worst.value <= limit)) {
        throw new LearningFailure(
          `${label} — worst ${worst.value.toPrecision(4)} exceeds ${limit} `
            + `at ${JSON.stringify(worst.item).slice(0, 160)}`
        );
      }
      record(label, `worst ${worst.value.toPrecision(3)} ≤ ${limit}`);
    },
  };
}

// MARK: - Fixture shape helpers

export const inputValue = (inputs, key) =>
  inputs?.find((entry) => entry.key === key)?.value ?? null;

export const glassBackground = (snapshot) =>
  snapshot?.model?.filters?.find((f) => f.name === "glassBackground") ?? null;

export function numeric(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

/** `g` is the transition's normalized progress, observable as face opacity. */
export function progressOf(snapshot) {
  const filter = glassBackground(snapshot);
  return filter ? numeric(inputValue(filter.inputs, "inputFaceOpacity")) : null;
}

export function shortSideOf(context) {
  return Math.min(context.glassWidth, context.glassHeight);
}

export function isClear(transition) {
  return String(transition.usage ?? "").includes("Clear");
}

/** The endpoint sample of a transition: the one settled at g = 1. */
export function endpointFilter(transition) {
  let best = null;
  for (const sample of transition.samples ?? []) {
    const filter = glassBackground(sample.snapshot);
    if (!filter) continue;
    const g = numeric(inputValue(filter.inputs, "inputFaceOpacity"));
    if (g === null) continue;
    if (!best || g > best.g) best = { g, filter };
  }
  return best && best.g > 0.999 ? best.filter : null;
}

// MARK: - The measured curve, mirrored from LiquidGlassLab/GlassMaterial

export const SHAPES = {
  linear: (g) => g,
  quadraticFlat: (g) => 0.2 * g + 0.8 * g * g,
  quadratic: (g) => 0.4 * g + 0.6 * g * g,
  height: (g, inflation) => g + inflation * g * (1 - g),
  clamp: (g) => (0.34 * g + 0.036 * g * g) / 0.376,
};

export const geometryInflation = (shortSide) =>
  shortSide > 0 ? Math.min(0.2, 16 / shortSide) : 0;

const LINEAR_FROM_ZERO = [
  "inputBleedColorMatrixBlack", "inputBleedDistance0", "inputBleedOpacity",
  "inputBlurDistance1", "inputBlurOpacity0", "inputBlurRadius",
  "inputFaceColorMatrixBlack", "inputFaceOpacity", "inputInnerRefractionAmount",
  "inputInnerRefractionHeight", "inputRefractionDistance0",
  "inputRefractionDistance1", "inputRefractionOpacity",
  "inputSDRGradientDistance0", "inputSDRGradientDistance1",
  "inputSDRShadowOpacity", "inputShadowAmount", "inputShadowBlurRadius",
  "inputShadowOpacity", "inputShadowRadius", "inputShadowVibrancyContribution",
];
const LINEAR_FROM_ONE = [
  "inputBleedColorMatrixSaturation", "inputBleedColorMatrixWhite",
  "inputFaceColorMatrixSaturation", "inputFaceColorMatrixWhite",
  "inputMaxHeadroom", "inputSDRHoldingToneWhite",
  "inputShadowColorMatrixSaturation", "inputShadowColorMatrixWhite",
];
const HEIGHT_FAMILY = [
  "inputBleedAmount", "inputBleedBlurRadius", "inputBleedHeight",
  "inputBlurDistance0", "inputBlurDistance4", "inputOuterRefractionAmount",
  "inputOuterRefractionHeight", "inputShadowHeight",
];

/** The channel table the shipping controller uses, kept in sync by hand. */
export function channelTable({ clear, main }) {
  const table = {};
  for (const key of LINEAR_FROM_ZERO) table[key] = { start: 0, shape: "linear" };
  for (const key of LINEAR_FROM_ONE) table[key] = { start: 1, shape: "linear" };
  for (const key of HEIGHT_FAMILY) table[key] = { start: 0, shape: "height" };
  table.inputBlurOpacity3 = { start: 0, shape: "quadratic" };
  table.inputBlurOpacity4 = { start: 0, shape: "quadratic" };
  const blur = main ? "quadratic" : "quadraticFlat";
  table.inputBlurOpacity1 = { start: 0, shape: blur };
  table.inputBlurOpacity2 = { start: 0, shape: blur };
  table.inputClamp = { start: 1, shape: clear ? "clamp" : "linear" };
  return table;
}

export function resolveChannel(channel, g, endpoint, inflation) {
  const shape = SHAPES[channel.shape];
  const factor = channel.shape === "height" ? shape(g, inflation) : shape(g);
  return channel.start + (endpoint - channel.start) * factor;
}
