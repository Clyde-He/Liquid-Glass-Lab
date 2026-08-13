import assert from "node:assert/strict";
import test from "node:test";
import { compareArchives, validateArchive } from "./lib/archive.mjs";

const property = (value, state = "value") => ({
  state,
  ...(state === "value" ? { value } : {}),
  attributes: {},
});
const number = (value) => ({ type: "number", number: value });
const color = (red, green, blue, alpha) => ({
  type: "color",
  color: {
    colorSpaceName: "kCGColorSpaceExtendedSRGB",
    model: "rgb",
    components: [red, green, blue, alpha],
    extendedSRGB: { red, green, blue, alpha },
  },
});
const matrix = () => ({
  type: "matrix",
  matrix: { objCType: "{CAColorMatrix=ffffffffffffffffffff}", coefficients: Array(20).fill(1) },
});

function cell(index, direction = null) {
  const height = index + 1;
  return {
    variant: 1, subvariant: null, main: false, key: false, subdued: false,
    appearance: "Light", backdrop: "Light", tint: "None",
    width: 480, height, cornerRadius: 16, host: "Panel", direction,
    shortSide: Math.min(480, height),
  };
}

function snapshot(shortSide, main = false) {
  const frame = { x: 0, y: 0, width: 480, height: shortSide };
  return {
    shortSide,
    layers: [
      {
        path: "root", layerClass: "CALayer", name: null, frame, bounds: frame,
        opacity: 1, isHidden: false, masksToBounds: false, cornerRadius: 0,
        hasMask: false, properties: {},
      },
      {
        path: "root.backdrop", layerClass: "CABackdropLayer", name: null,
        frame, bounds: frame, opacity: 1, isHidden: false, masksToBounds: false,
        cornerRadius: 16, hasMask: false,
        properties: {
          marginWidth: property(number(main ? Math.max(16, shortSide * 0.35) : 0.5)),
        },
      },
      {
        path: "root.rim", layerClass: "CASDFLayer", name: null, frame,
        bounds: frame, opacity: main ? 1 : 0, isHidden: false, masksToBounds: false,
        cornerRadius: 16, hasMask: false, properties: {},
      },
    ],
    passes: [
      {
        id: "shader", order: 0, layerPath: "root.backdrop",
        layerClass: "CABackdropLayer", location: "filters",
        objectClass: "CAFilter", name: "glassBackground",
        properties: {
          inputFaceOpacity: property(number(1)),
          inputShadowAmount: property(number(main ? 30 : 0)),
          inputInnerRefractionAmount: property(number(main ? -30 : 0)),
          inputInnerRefractionHeight: property(number(main ? 20 : 0)),
          inputMaxHeadroom: property(number(9_999)),
          inputFaceColorMatrixFillColor: property(color(1, 0.5, 0.25, 0.75)),
          inputOptional: property(null, "nil"),
        },
      },
      ...[1, 2].map((order) => ({
        id: `matrix-${order}`, order, layerPath: `root.matrix-${order}`,
        layerClass: "CALayer", location: "filters", objectClass: "CAFilter",
        name: "vibrantColorMatrix",
        properties: {
          inputColorMatrix: property(matrix()),
          inputClamp: property(number(order)),
          inputOptional: property(null, "nil"),
        },
      })),
      {
        id: "rim", order: 3, layerPath: "root.rim", layerClass: "CASDFLayer",
        location: "effect", objectClass: "CASDFKeyFillHighlightEffect", name: null,
        properties: {
          curvature: property(number(0.75)),
          fillColor: property(color(1, 1, 1, 0.5)),
          keyColor: property(color(1, 1, 1, 0.25)),
        },
      },
      {
        id: "output", order: 4, layerPath: "root.output", layerClass: "CASDFLayer",
        location: "effect", objectClass: "CASDFOutputEffect", name: null,
        properties: { minimum: property(number(-10_000)), maximum: property(number(39.8)) },
      },
    ],
  };
}

const phases = [
  "preflight", "trigger", "sample", "sample", "sample",
  "sample", "sample", "endpoint", "settled",
];
const requested = [0, 0, 0.125, 0.25, 0.5, 0.75, 0.875, 1, 1];

function samples(start, end) {
  return phases.map((phase, index) => ({
    progress: null,
    requestedProgress: requested[index], elapsed: index, phase,
    filters: [], effects: [],
    layerLines: [index === 0 ? start : index === 8 ? end : `sample-${index}`],
  }));
}

function run(index, slice, direction, start = "absent", end = "present") {
  return {
    cell: cell(index, direction), accepted: true, slice, usage: "Regular",
    effectiveAppearance: "NSAppearanceNameAqua", tintComponents: null,
    animationMode: "Linear", maximumAttachedAnimationDuration: 1,
    samples: samples(start, end),
  };
}

function dynamicRuns() {
  const runs = [];
  for (let index = 0; index < 48; index += 1) {
    runs.push(run(index, "core", "insertion"));
    runs.push(run(index, "core", "removal", "present", "absent"));
  }
  for (let index = 0; index < 4; index += 1) {
    runs.push(run(100 + index, "backdrop", "insertion"));
    runs.push(run(200 + index, "repeat", "insertion"));
  }
  return runs;
}

function tintCell(index) {
  return {
    isLightAppearance: index < 4,
    isClear: index % 4 >= 2,
    hasMainParticipation: index % 2 === 0,
  };
}

function parameterizationDocument(os, display) {
  return {
    formatVersion: 1, operatingSystem: os, capturedAt: "2026-08-12T00:00:00Z",
    complete: true, completedColorCount: 1,
    environment: { atlasSchemaVersion: 2, displaySignature: display, osMajorVersion: 27 },
    plan: { colors: [{ id: "color" }] },
    rows: Array.from({ length: 8 }, (_, index) => ({
      cell: tintCell(index), colorID: "color", matrix: Array(20).fill(index),
    })),
  };
}

function pairedTintDocument(os, display) {
  return {
    formatVersion: 2, operatingSystem: os, capturedAt: "2026-08-12T00:00:00Z",
    passed: true,
    plannedColorIDs: ["color"],
    environment: { atlasSchemaVersion: 2, displaySignature: display, osMajorVersion: 27 },
    rows: Array.from({ length: 8 }, (_, index) => ({
      cell: tintCell(index), colorID: "color", flushMatrix: Array(20).fill(index),
      settledMatrix: Array(20).fill(index), maximumDifference: 0, passed: true,
      pairedProofAtFlush: true, pairedProofWhenSettled: true,
    })),
    timings: [{ colorID: "color" }],
  };
}

const catalogShortSides = [48, 64, 96, 128, 160, 200, 320];

function catalogCell(appearance, variant, main, shortSide) {
  return {
    variant, subvariant: null, main, key: false, subdued: false,
    appearance, backdrop: "Light", tint: "None", width: 480,
    height: shortSide, shortSide, cornerRadius: 16, host: "Panel", direction: null,
  };
}

function semanticDocument(os) {
  return {
    formatVersion: 2, operatingSystem: os,
    context: { hostType: "Panel", glassWidth: 480, glassHeight: 200, cornerRadius: 16 },
    entries: Array.from({ length: 48 }, (_, index) => {
      const requestedMain = index % 2 === 1;
      return {
        roleTag: Math.floor(index / 2), requestedMain, actualMain: requestedMain,
        actualKey: false, isAvailable: true,
        snapshot: { layerLines: ["root"], filters: [], effects: [] },
      };
    }),
  };
}

function archive() {
  const operatingSystem = "Version 27.0 (Build 26A5406e)";
  const displaySignature = "Studio Display XDR @2.0x";
  const consumerCells = ["Dark", "Light"].flatMap((appearance) =>
    [1, 2].flatMap((variant) => [false, true].flatMap((main) =>
      catalogShortSides.map((shortSide) => catalogCell(
        appearance, variant, main, shortSide
      )))));
  const observations = consumerCells.map((value) => ({
    cell: value, snapshot: snapshot(value.shortSide, value.main),
  }));
  for (let index = observations.length; index < 776; index += 1) {
    const value = {
      ...cell(index + 1000), variant: 10, height: index + 1000, shortSide: 480,
    };
    observations.push({ cell: value, snapshot: snapshot(value.shortSide) });
  }
  const parameterization = parameterizationDocument(operatingSystem, displaySignature);
  const paired = pairedTintDocument(operatingSystem, displaySignature);
  return {
    directory: "/tmp/fixture", platform: {
      product: "macOS", version: "27.0", major: 27, build: "26A5406e",
      architecture: "arm64", displaySignature,
    },
    capture: {
      schemaVersion: 2, operatingSystem, architecture: "arm64",
      displaySignature, capturedAt: "2026-08-12T00:00:00Z",
    },
    static: {
      schemaVersion: 2,
      consumerCells,
      observations,
    },
    dynamic: { schemaVersion: 2, runs: dynamicRuns() },
    tintSweep: structuredClone(parameterization),
    tintFocused: structuredClone(parameterization),
    tintHue: structuredClone(parameterization),
    tintSync: structuredClone(paired),
    tintWideGamut: structuredClone(paired),
    semantic: semanticDocument(operatingSystem),
  };
}

test("one archive contract admits complete measured evidence", () => {
  assert.deepEqual(validateArchive(archive()), []);
});

test("archive contract rejects missing coverage and unreadable Consumer evidence", () => {
  const candidate = archive();
  candidate.static.observations.shift();
  candidate.static.observations[0].snapshot.passes[0].properties.inputFaceOpacity =
    property(null, "unreadable");
  const problems = validateArchive(candidate);
  assert.ok(problems.some((problem) => problem.includes("has no Static observation")));
  assert.ok(problems.some((problem) => problem.includes("cannot project")));
});

test("macOS 26 has the same archive model without inventing Semantic evidence", () => {
  const candidate = archive();
  candidate.capture.operatingSystem = "Version 26.6 (Build 25G70)";
  candidate.platform = {
    ...candidate.platform, version: "26.6", major: 26, build: "25G70",
  };
  for (const key of [
    "tintSweep", "tintFocused", "tintHue", "tintSync", "tintWideGamut",
  ]) candidate[key].operatingSystem = candidate.capture.operatingSystem;
  candidate.semantic = null;
  assert.deepEqual(validateArchive(candidate), []);
});

test("paired Tint evidence cannot pass with empty or partial planned coverage", () => {
  const empty = archive();
  empty.tintSync.rows = [];
  assert.ok(validateArchive(empty).some((problem) =>
    problem.includes("tint.sync-resolution has no rows")));

  const partial = archive();
  partial.tintWideGamut.rows.pop();
  assert.ok(validateArchive(partial).some((problem) =>
    problem.includes("does not cover 8 unique cells")));
});

test("Dynamic removal must continue from the exact paired insertion endpoint", () => {
  const candidate = archive();
  candidate.dynamic.runs[1].samples[0].layerLines = ["independent warm-up endpoint"];
  assert.ok(validateArchive(candidate).some((problem) =>
    problem.includes("preflight does not match insertion run")));
});

test("whole-archive comparison reports value drift without inventing module gates", () => {
  const baseline = archive();
  const candidate = structuredClone(baseline);
  candidate.directory = "/tmp/candidate";
  candidate.static.observations[0].snapshot.passes[0]
    .properties.inputFaceOpacity.value.number = 0.9;
  const report = compareArchives(baseline, candidate);
  assert.equal(report.equivalent, false);
  assert.equal(report.static.changedObservations, 1);
  assert.equal(report.static.topologyChangedObservations, 0);
});

test("session-volatile headroom is reported without turning honest drift red", () => {
  const baseline = archive();
  const candidate = structuredClone(baseline);
  candidate.static.observations[0].snapshot.passes[0]
    .properties.inputMaxHeadroom.value.number = 1.2;
  baseline.dynamic.runs[0].samples[0].filters = [{ inputMaxHeadroom: 9_999 }];
  baseline.dynamic.runs[1].samples[8].filters = [{ inputMaxHeadroom: 9_999 }];
  candidate.dynamic.runs[0].samples[0].filters = [{ inputMaxHeadroom: 1.2 }];
  candidate.dynamic.runs[1].samples[8].filters = [{ inputMaxHeadroom: 1.2 }];
  baseline.semantic.entries[0].snapshot.filters = [{ inputMaxHeadroom: 9_999 }];
  candidate.semantic.entries[0].snapshot.filters = [{ inputMaxHeadroom: 1.2 }];
  const report = compareArchives(baseline, candidate);
  assert.equal(report.equivalent, true);
  assert.equal(report.static.volatile.inputMaxHeadroomChangedObservations, 1);
  assert.equal(report.static.volatile.inputMaxHeadroomDifferences, 1);
  assert.ok(report.static.volatile.examples.length > 0);
  assert.equal(report.dynamic.volatile.inputMaxHeadroom.differences, 2);
  assert.ok(report.dynamic.volatile.inputMaxHeadroom.examples.length > 0);
  const semantic = report.documents.find(
    ({ file }) => file === "semantic-usage-trees.json"
  );
  assert.equal(semantic.volatile.inputMaxHeadroom.differences, 1);
  assert.ok(semantic.volatile.inputMaxHeadroom.examples.length > 0);
});
