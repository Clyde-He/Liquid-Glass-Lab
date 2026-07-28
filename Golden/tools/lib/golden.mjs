// Shared loading and assertion helpers for the learning suite.
//
// A "learning" is one accepted finding from Documentation/, expressed as an
// executable assertion over the archive. The point is that re-validating the
// whole body of knowledge on a new OS becomes one command instead of a manual
// reread.
//
// Learnings read the unified archive under `<os>/unified/`, whose three
// sections all address rows by the same cell coordinate (see cell.mjs). A
// learning declares the sections it needs and, if it is a `cross-version` one,
// receives every OS at once.

import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CELL_FIELDS, axisValues, sweptAxes } from "./cell.mjs";

// .../Golden/tools/lib/golden.mjs -> .../Golden
export const goldenDirectory = path.dirname(
  path.dirname(path.dirname(fileURLToPath(import.meta.url)))
);

export const SECTIONS = ["static-scalar", "static-tree", "dynamic"];

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
 * Loads the unified sections of one OS directory. A section this OS has not
 * captured resolves to null, which is how a learning reports "not applicable
 * here" rather than failing.
 */
export async function loadUnified(osDirectory) {
  const directory = path.join(goldenDirectory, osDirectory, "unified");
  let archiveRole = null;
  try {
    archiveRole = JSON.parse(
      await readFile(path.join(directory, "meta.json"), "utf8")
    ).role ?? null;
  } catch {
    // Section loading below remains authoritative for older archives whose
    // meta predates the role field.
  }
  const sections = {};
  for (const name of SECTIONS) {
    try {
      const document = normalizeUnifiedDocument(JSON.parse(
        await readFile(path.join(directory, `${name}.json`), "utf8")
      ));
      sections[name] = { ...document, archiveRole };
    } catch {
      sections[name] = null;
    }
  }
  return sections;
}

/**
 * Direct captures do not duplicate their cell axes into every section. Derive
 * them at read time from the authoritative rows while retaining any declared
 * values written by the historical unifier.
 */
export function normalizeUnifiedDocument(document) {
  const rows = document?.rows ?? document?.runs ?? [];
  const cells = rows.map((row) => row.cell ?? {});
  const derivedValues = Object.fromEntries(
    CELL_FIELDS.map((field) => [field, axisValues(cells, field)])
  );
  const declaredValues = document?.axes?.values ?? {};
  return {
    ...document,
    axes: {
      values: { ...derivedValues, ...declaredValues },
      swept: document?.axes?.swept ?? sweptAxes(cells),
    },
  };
}

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

// MARK: - Assertions

export class LearningFailure extends Error {}

/**
 * Thrown when the archive cannot decide the claim either way — the axis the
 * learning needs was never swept. This exists because the alternative, an
 * `ok(true, "not present here")` escape hatch, reports green for a claim
 * nothing checked. A learning that cannot run must say so out loud.
 */
export class Unverifiable extends Error {}

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
    /** The archive cannot settle this claim. Reported as a skip, never a pass. */
    unverifiable(reason) {
      throw new Unverifiable(reason);
    },
    /** Guard form: skip unless the archive swept enough to decide anything. */
    requireSamples(count, minimum, label) {
      if (count < minimum) {
        throw new Unverifiable(`${label} — ${count} available, need ${minimum}`);
      }
      record(label, `${count}`);
    },
  };
}

// MARK: - Unified fixture shape helpers

export const numeric = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

/** Inputs are `{key: value}` maps in the unified archive. */
export const filterNamed = (sample, name) =>
  sample?.filters?.find((filter) => filter.name === name) ?? null;

export const glassBackground = (sample) => filterNamed(sample, "glassBackground");

export const glassInput = (sample, key) =>
  numeric(glassBackground(sample)?.inputs?.[key]);

/** `g` is the transition's normalized progress, observable as face opacity. */
export const progressOf = (sample) =>
  sample?.progress ?? glassInput(sample, "inputFaceOpacity");

/** The settled sample of a run, i.e. the one at g = 1. Null if it never got there. */
export function endpointSample(run) {
  let best = null;
  for (const sample of run.samples ?? []) {
    const g = progressOf(sample);
    if (g === null) continue;
    // Several channels and the View Envelope can still be settling after face
    // opacity first reaches 1. Prefer the latest equally complete sample so an
    // early saturated frame cannot masquerade as the resolved endpoint.
    if (!best || g >= best.g) best = { g, sample };
  }
  return best && best.g > 0.999 ? best.sample : null;
}

export const endpointInputs = (run) =>
  glassBackground(endpointSample(run))?.inputs ?? null;

/** Supports both transcoded legacy runs and direct-capture runs. */
export const tintComponents = (run) =>
  run?.tintComponents ?? run?.tint?.components ?? null;

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

// macOS 27 rebuilt Regular's shadow: `inputShadowHeight` resolves to 0 and a
// size-invariant ring shadow takes over, arriving with a blur fill and a key
// fill highlight. Every one of the 17 new animating inputs rides the same clock
// as `inputFaceOpacity` — normalized against its own start each traces the face
// profile to within 1e-3 — so all of them are linear and only the start values
// are new. Absent on macOS 26, where the controller skips them for want of an
// endpoint, which is why one table serves both systems with no version branch.
const LINEAR_FROM_ZERO_27 = [
  "inputBlurFillBlurRadius", "inputBlurFillDarkenOpacity",
  "inputBlurFillLightenOpacity", "inputBlurFillNormalOpacity",
  "inputKeyFillHighlightEffectOffset", "inputKeyFillHighlightHeight",
  "inputRingShadowOffset", "inputRingShadowOpacity",
  "inputRingShadowStrokeWidth",
];
const LINEAR_FROM_ONE_27 = [
  "inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR",
  "inputRingShadowBlurRadius", "inputRingShadowMask",
];
/**
 * The starts macOS 27 introduced that are neither 0 nor 1. Measured constants,
 * invariant across size, participation, appearance, and Variant; a wrong start
 * bows the normalized profile away from the face curve, and none of these do.
 */
const LINEAR_FROM_MEASURED_27 = {
  inputKeyFillHighlightAmount: 0.4,
  inputKeyFillHighlightColorBias: -0.25,
  inputKeyFillHighlightSpread: 1.309,
  inputKeyFillHighlightSpreadSDR: 1.309,
};

/** The channel table the shipping controller uses, kept in sync by hand. */
export function channelTable({ clear, main }) {
  const table = {};
  for (const key of LINEAR_FROM_ZERO) table[key] = { start: 0, shape: "linear" };
  for (const key of LINEAR_FROM_ONE) table[key] = { start: 1, shape: "linear" };
  for (const key of HEIGHT_FAMILY) table[key] = { start: 0, shape: "height" };
  for (const key of LINEAR_FROM_ZERO_27) table[key] = { start: 0, shape: "linear" };
  for (const key of LINEAR_FROM_ONE_27) table[key] = { start: 1, shape: "linear" };
  for (const [key, start] of Object.entries(LINEAR_FROM_MEASURED_27)) {
    table[key] = { start, shape: "linear" };
  }
  table.inputBlurOpacity3 = { start: 0, shape: "quadratic" };
  table.inputBlurOpacity4 = { start: 0, shape: "quadratic" };
  const blur = main ? "quadratic" : "quadraticFlat";
  table.inputBlurOpacity1 = { start: 0, shape: blur };
  table.inputBlurOpacity2 = { start: 0, shape: blur };
  table.inputClamp = { start: 1, shape: clear ? "clamp" : "linear" };
  // macOS 27 gates the backdrop blur by size, and the transition overshoots by
  // exactly the amount the gated endpoint falls short of full opacity. See the
  // Swift table for the derivation; the term vanishes wherever the endpoint is
  // 1, which is every macOS 26 cell and every Clear cell on either system.
  table.inputBlurOpacity0 = {
    start: 0,
    shape: "linear",
    saturationDeficitHump: true,
  };
  return table;
}

/** Every continuous channel the table knows about, independent of context. */
export const CONTINUOUS_CHANNELS = [
  ...LINEAR_FROM_ZERO, ...LINEAR_FROM_ONE, ...HEIGHT_FAMILY,
  ...LINEAR_FROM_ZERO_27, ...LINEAR_FROM_ONE_27,
  ...Object.keys(LINEAR_FROM_MEASURED_27),
  "inputBlurOpacity1", "inputBlurOpacity2", "inputBlurOpacity3",
  "inputBlurOpacity4", "inputClamp",
];

/** Numeric inputs that switch at a measured edge rather than interpolate. */
export const DISCRETE_CHANNELS = [
  "inputBleedDarkenBlend",
  "inputSDRHoldingToneEnabled",
];

/** Every numeric background channel the Materialize abstraction controls. */
export const ALL_CHANNELS = [
  ...CONTINUOUS_CHANNELS,
  ...DISCRETE_CHANNELS,
];

export function resolveChannel(channel, g, endpoint, inflation) {
  const shape = SHAPES[channel.shape];
  const factor = channel.shape === "height" ? shape(g, inflation) : shape(g);
  const base = channel.start + (endpoint - channel.start) * factor;
  return channel.saturationDeficitHump
    ? base + (1 - endpoint) * g * (1 - g)
    : base;
}
