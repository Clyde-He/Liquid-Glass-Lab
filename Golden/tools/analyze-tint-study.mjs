#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const inputPath = process.argv[2];
if (!inputPath) {
  console.error("Usage: node Golden/analyze-tint-study.mjs <glass-tint-study.json>");
  process.exit(2);
}

const document = JSON.parse(await readFile(inputPath, "utf8"));
const appKitRows = document.appKitStatic ?? [];
const swiftUIRows = document.swiftUIStatic ?? [];
const transitions = document.swiftUITransitions ?? [];

const matrixPattern = /ColorMatrix4x5\(\[([^\]]+)\];sha256=[0-9a-f]+\)/;

function parseMatrix(value) {
  if (typeof value !== "string") return null;
  const match = value.match(matrixPattern);
  if (!match) return null;
  const numbers = match[1].split(",").map(Number);
  return numbers.length === 20 && numbers.every(Number.isFinite)
    ? numbers
    : null;
}

function inputValue(inputs, key) {
  return inputs?.find((entry) => entry.key === key)?.value ?? null;
}

function appKitTintMatrix(snapshot) {
  const passes = Object.values(snapshot?.passes ?? {});
  const tintEffect = passes.find(
    (pass) => pass.objectClass === "CASDFGradientEffect"
  );
  if (!tintEffect) return null;
  const tintMatrix = passes.find(
    (pass) =>
      pass.layerPath === tintEffect.layerPath &&
      pass.name === "vibrantColorMatrix"
  );
  return parseMatrix(
    tintMatrix?.properties?.inputColorMatrix?.value
  );
}

function semanticTintInfo(snapshot) {
  const model = snapshot?.model;
  const tintEffect = model?.effects?.find(
    (effect) => effect.effectClass === "CASDFGradientEffect"
  );
  if (!tintEffect) return null;
  const tintFilter = model?.filters?.find(
    (filter) =>
      filter.path === tintEffect.path &&
      filter.name === "vibrantColorMatrix"
  );
  const matrix = parseMatrix(inputValue(tintFilter?.inputs, "inputColorMatrix"));
  if (!matrix) return null;
  const layer = snapshot?.modelLayers?.find(
    (candidate) =>
      candidate.layerClass === "CASDFElementLayer" &&
      candidate.path.startsWith(`${tintEffect.path}.`)
  );
  return { matrix, path: tintEffect.path, layer };
}

function semanticGlassProgress(snapshot) {
  const filter = snapshot?.model?.filters?.find(
    (candidate) => candidate.name === "glassBackground"
  );
  const value = Number(inputValue(filter?.inputs, "inputFaceOpacity"));
  return Number.isFinite(value) ? value : null;
}

function tintAlpha(tint) {
  const alpha = tint?.components?.[3];
  return Number.isFinite(alpha) ? alpha : null;
}

function rowKey(material, requestedMain, tintLabel) {
  return `${material}|${requestedMain ? "main" : "flat"}|${tintLabel}`;
}

function maxAbsDifference(left, right, excluded = new Set()) {
  if (!left || !right || left.length !== right.length) return Infinity;
  let maximum = 0;
  for (let index = 0; index < left.length; index += 1) {
    if (excluded.has(index)) continue;
    maximum = Math.max(maximum, Math.abs(left[index] - right[index]));
  }
  return maximum;
}

function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function comparableStoredTint(row) {
  const requested = row.tint?.components ?? null;
  const stored = row.storedTint?.components ?? null;
  if (!requested && !stored) return 0;
  if (!requested || !stored || requested.length !== stored.length) {
    return Infinity;
  }
  return maxAbsDifference(requested, stored);
}

const appKitTopologySignatures = new Set(
  appKitRows.map((row) => row.snapshot?.model?.topologySignature)
);
const appKitPassCounts = new Set(
  appKitRows.map((row) => Object.keys(row.snapshot?.model?.passes ?? {}).length)
);

let staticAlphaMaximumError = 0;
let storedTintMaximumError = 0;
for (const row of appKitRows) {
  storedTintMaximumError = Math.max(
    storedTintMaximumError,
    comparableStoredTint(row)
  );
  const alpha = tintAlpha(row.tint);
  const matrix = appKitTintMatrix(row.snapshot?.model);
  if (alpha !== null && matrix) {
    staticAlphaMaximumError = Math.max(
      staticAlphaMaximumError,
      Math.abs(matrix[18] - alpha)
    );
  }
}

const appKitComparable = new Map();
for (const row of appKitRows) {
  if (row.tint?.reducedTintOpacity) continue;
  appKitComparable.set(
    rowKey(row.material, row.requestedMain, row.tint.label),
    appKitTintMatrix(row.snapshot?.model)
  );
}

let appKitSwiftUIParityMaximumError = 0;
let appKitSwiftUIParityRows = 0;
for (const row of swiftUIRows) {
  const swiftMatrix = semanticTintInfo(row.snapshot)?.matrix ?? null;
  const appKitMatrix = appKitComparable.get(
    rowKey(row.usage, row.requestedMain, row.tint.label)
  );
  if (!swiftMatrix || !appKitMatrix) continue;
  appKitSwiftUIParityRows += 1;
  appKitSwiftUIParityMaximumError = Math.max(
    appKitSwiftUIParityMaximumError,
    maxAbsDifference(swiftMatrix, appKitMatrix)
  );
  const alpha = tintAlpha(row.tint);
  if (alpha !== null) {
    staticAlphaMaximumError = Math.max(
      staticAlphaMaximumError,
      Math.abs(swiftMatrix[18] - alpha)
    );
  }
}

let mainOffHueMaximumDifference = 0;
for (const material of ["Regular", "Clear"]) {
  const coral = appKitComparable.get(
    rowKey(material, false, "Coral · 50%")
  );
  const cyan = appKitComparable.get(
    rowKey(material, false, "Cyan · 50%")
  );
  mainOffHueMaximumDifference = Math.max(
    mainOffHueMaximumDifference,
    maxAbsDifference(coral, cyan)
  );
}

const reducedComparisons = [];
for (const row of appKitRows.filter((entry) => entry.tint?.reducedTintOpacity)) {
  const baselineLabel = row.tint.label.replace(" · Reduced", "");
  const baseline = appKitRows.find(
    (candidate) =>
      candidate.material === row.material &&
      candidate.requestedMain === row.requestedMain &&
      !candidate.tint?.reducedTintOpacity &&
      candidate.tint?.label === baselineLabel
  );
  reducedComparisons.push({
    material: row.material,
    requestedMain: row.requestedMain,
    tint: row.tint.label,
    exactSnapshotMatch:
      baseline !== undefined &&
      stableJSON(row.snapshot) === stableJSON(baseline.snapshot),
  });
}

const swiftStaticByKey = new Map(
  swiftUIRows.map((row) => [
    rowKey(row.usage, row.requestedMain, row.tint.label),
    semanticTintInfo(row.snapshot)?.matrix ?? null,
  ])
);

let transitionTintSamples = 0;
let transitionPresentationTintSamples = 0;
let transitionAttachedAnimations = 0;
let transitionMaximumNonAlphaEndpointError = 0;
let tintSquaredMaximumResidual = 0;
let tintSquaredSumOfSquares = 0;
let tintLinearMaximumResidual = 0;
let tintGeometryMaximumResidual = 0;
let squaredResidualCount = 0;
const branchPresence = {};

for (const transition of transitions) {
  const sourceAlpha = tintAlpha(transition.context?.tint);
  const endpointMatrix = swiftStaticByKey.get(
    rowKey(
      transition.usage,
      transition.context?.requestedMain,
      transition.context?.tint?.label
    )
  );
  for (const sample of transition.samples ?? []) {
    transitionAttachedAnimations += sample.snapshot?.animations?.length ?? 0;
    const modelInfo = semanticTintInfo(sample.snapshot);
    const presentationInfo = semanticTintInfo({
      model: sample.snapshot?.presentation,
      modelLayers: sample.snapshot?.presentationLayers,
    });
    const branchKey = `${transition.direction}:${sample.phase}`;
    branchPresence[branchKey] ??= { samples: 0, model: 0, presentation: 0 };
    branchPresence[branchKey].samples += 1;
    if (modelInfo) {
      branchPresence[branchKey].model += 1;
      transitionTintSamples += 1;
    }
    if (presentationInfo) {
      branchPresence[branchKey].presentation += 1;
      transitionPresentationTintSamples += 1;
    }
    if (!modelInfo || sourceAlpha === null) continue;

    transitionMaximumNonAlphaEndpointError = Math.max(
      transitionMaximumNonAlphaEndpointError,
      maxAbsDifference(modelInfo.matrix, endpointMatrix, new Set([18]))
    );

    const progress = semanticGlassProgress(sample.snapshot);
    if (progress === null) continue;
    const observedAlpha = modelInfo.matrix[18];
    const squaredResidual = observedAlpha - sourceAlpha * progress * progress;
    tintSquaredMaximumResidual = Math.max(
      tintSquaredMaximumResidual,
      Math.abs(squaredResidual)
    );
    tintSquaredSumOfSquares += squaredResidual * squaredResidual;
    tintLinearMaximumResidual = Math.max(
      tintLinearMaximumResidual,
      Math.abs(observedAlpha - sourceAlpha * progress)
    );
    squaredResidualCount += 1;

    if (modelInfo.layer) {
      const expectedWidth =
        document.context.glassWidth + 16 * (1 - progress);
      const expectedHeight =
        document.context.glassHeight + 16 * (1 - progress);
      tintGeometryMaximumResidual = Math.max(
        tintGeometryMaximumResidual,
        Math.abs(modelInfo.layer.boundsWidth - expectedWidth),
        Math.abs(modelInfo.layer.boundsHeight - expectedHeight)
      );
    }
  }
}

const reducedSetterRows = appKitRows.filter(
  (row) => row.tint?.reducedTintOpacity
);
const validationFailures = [];
if (appKitRows.length !== 28) {
  validationFailures.push(`Expected 28 AppKit rows, found ${appKitRows.length}`);
}
if (swiftUIRows.length !== 20) {
  validationFailures.push(
    `Expected 20 SwiftUI static rows, found ${swiftUIRows.length}`
  );
}
if (transitions.length !== 40) {
  validationFailures.push(
    `Expected 40 transitions, found ${transitions.length}`
  );
}
if (
  transitions.some(
    (transition) =>
      transition.samples?.length !== 9 ||
      transition.context?.actualMain !== transition.context?.requestedMain ||
      transition.context?.actualKey !== false
  )
) {
  validationFailures.push(
    "A transition has incomplete samples or rejected Main/Key context"
  );
}
if (
  [...appKitRows, ...swiftUIRows].some(
    (row) =>
      row.actualMain !== row.requestedMain ||
      row.actualKey !== false
  )
) {
  validationFailures.push(
    "A static row has rejected Main/Key context"
  );
}
if (appKitSwiftUIParityRows !== 16) {
  validationFailures.push(
    `Expected 16 comparable nonnil Tint rows, found ${appKitSwiftUIParityRows}`
  );
}

const summary = {
  source: inputPath,
  validation: {
    passed: validationFailures.length === 0,
    failures: validationFailures,
  },
  environment: {
    operatingSystem: document.operatingSystem,
    capturedAt: document.capturedAt,
    context: document.context,
  },
  counts: {
    appKitStatic: appKitRows.length,
    swiftUIStatic: swiftUIRows.length,
    transitions: transitions.length,
    transitionSamples: transitions.reduce(
      (sum, transition) => sum + (transition.samples?.length ?? 0),
      0
    ),
  },
  staticRouting: {
    topologySignatureCount: appKitTopologySignatures.size,
    passCounts: [...appKitPassCounts].sort((left, right) => left - right),
    appKitSwiftUIComparableTintRows: appKitSwiftUIParityRows,
    appKitSwiftUIMatrixMaximumError: appKitSwiftUIParityMaximumError,
    tintAlphaCoefficientMaximumError: staticAlphaMaximumError,
    mainOffCoralVsCyanMatrixMaximumDifference: mainOffHueMaximumDifference,
    tintColorReadbackMaximumError: storedTintMaximumError,
  },
  reducedTintOpacity: {
    requestedRows: reducedSetterRows.length,
    setterAvailableRows: reducedSetterRows.filter(
      (row) => row.reducedTintOpacitySetterAvailable === true
    ).length,
    getterAvailableRows: reducedSetterRows.filter(
      (row) => row.reducedTintOpacityGetterAvailable === true
    ).length,
    getterReadableRows: reducedSetterRows.filter(
      (row) => row.storedReducedTintOpacity !== undefined
    ).length,
    exactSnapshotMatches: reducedComparisons.filter(
      (comparison) => comparison.exactSnapshotMatch
    ).length,
    comparisons: reducedComparisons,
  },
  materialize: {
    modelTintBranchSamples: transitionTintSamples,
    presentationTintBranchSamples: transitionPresentationTintSamples,
    attachedAnimations: transitionAttachedAnimations,
    nonAlphaCoefficientMaximumEndpointError:
      transitionMaximumNonAlphaEndpointError,
    alphaEqualsSourceAlphaTimesGSquared: {
      sampleCount: squaredResidualCount,
      maximumResidual: tintSquaredMaximumResidual,
      rmsResidual: Math.sqrt(
        tintSquaredSumOfSquares / Math.max(squaredResidualCount, 1)
      ),
      competingLinearMaximumResidual: tintLinearMaximumResidual,
    },
    tintSDFBoundsMaximumResidual: tintGeometryMaximumResidual,
    branchPresence,
  },
};

console.log(JSON.stringify(summary, null, 2));
if (validationFailures.length > 0) process.exitCode = 1;
