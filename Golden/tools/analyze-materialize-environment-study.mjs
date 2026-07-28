#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const inputPath = process.argv[2];
if (!inputPath) {
  console.error(
    "Usage: bun Golden/analyze-materialize-environment-study.mjs "
      + "<glass-materialize-p1-matrix.json>"
  );
  process.exit(2);
}

const document = JSON.parse(await readFile(inputPath, "utf8"));
const transitions = document.transitions ?? [];
const expectedMaterials = ["Regular", "Clear"];
const expectedMain = [false, true];
const expectedAppearances = ["Light", "Dark"];
const expectedBackdrops = ["Light", "Dark"];
const expectedTints = ["None", "Coral · 50%"];
const expectedDirections = ["Insertion", "Removal"];
const matrixPattern =
  /ColorMatrix4x5\(\[([^\]]+)\];sha256=[0-9a-f]+\)/;
const numericChannelCache = new WeakMap();

function inputValue(inputs, key) {
  return inputs?.find((entry) => entry.key === key)?.value ?? null;
}

function glassProgress(snapshot) {
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

function tintMatrix(snapshot) {
  const model = snapshot?.model;
  const tintEffect = model?.effects?.find(
    (effect) => effect.effectClass === "CASDFGradientEffect"
  );
  if (!tintEffect) return null;
  const filter = model?.filters?.find(
    (candidate) =>
      candidate.path === tintEffect.path
      && candidate.name === "vibrantColorMatrix"
  );
  const value = inputValue(filter?.inputs, "inputColorMatrix");
  if (typeof value !== "string") return null;
  const match = value.match(matrixPattern);
  if (!match) return null;
  const numbers = match[1].split(",").map(Number);
  return numbers.length === 20 && numbers.every(Number.isFinite)
    ? numbers
    : null;
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

function captureKey(capture) {
  const context = capture.context ?? {};
  return [
    capture.usage,
    context.requestedMain ? "main" : "flat",
    context.requestedAppearance,
    context.backdrop,
    context.tint?.label,
    capture.direction,
  ].join("|");
}

function comparisonKey(capture) {
  const context = capture.context ?? {};
  return [
    capture.usage,
    context.requestedMain ? "main" : "flat",
    context.tint?.label,
    capture.direction,
  ].join("|");
}

function environmentKey(capture) {
  return [
    capture.context?.requestedAppearance,
    capture.context?.backdrop,
  ].join("|");
}

function sampleKey(sample) {
  return `${sample.phase}|${sample.requestedProgress}`;
}

function topologySignature(snapshot) {
  const model = snapshot?.model;
  const layers = (snapshot?.modelLayers ?? []).map((layer) => [
    layer.path,
    layer.layerClass,
    layer.name ?? null,
  ]);
  const filters = (model?.filters ?? []).map((filter) => [
    filter.path,
    filter.layerClass,
    filter.location,
    filter.name,
    (filter.inputs ?? []).map((input) => input.key).sort(),
  ]);
  const effects = (model?.effects ?? []).map((effect) => [
    effect.path,
    effect.layerClass,
    effect.effectClass,
    (effect.inputs ?? []).map((input) => input.key).sort(),
  ]);
  return stableJSON({ layers, filters, effects });
}

function modelValueSignature(snapshot) {
  const model = snapshot?.model;
  const layers = (snapshot?.modelLayers ?? []).map((layer) => ({
    path: layer.path,
    frame: [
      layer.frameX,
      layer.frameY,
      layer.frameWidth,
      layer.frameHeight,
    ],
    bounds: [
      layer.boundsX,
      layer.boundsY,
      layer.boundsWidth,
      layer.boundsHeight,
    ],
    position: [layer.positionX, layer.positionY],
    opacity: layer.opacity,
    transform: layer.transform,
    sublayerTransform: layer.sublayerTransform,
    affineTransform: layer.affineTransform,
    backgroundColor: layer.backgroundColor,
    borderColor: layer.borderColor,
    shadowColor: layer.shadowColor,
  }));
  return stableJSON({
    filters: model?.filters ?? [],
    effects: model?.effects ?? [],
    layers,
  });
}

function parseNumericVector(value) {
  if (typeof value === "number" && Number.isFinite(value)) return [value];
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (/^-?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?$/i.test(trimmed)) {
    return [Number(trimmed)];
  }
  const matrixMatch = trimmed.match(matrixPattern);
  if (matrixMatch) {
    const numbers = matrixMatch[1].split(",").map(Number);
    return numbers.every(Number.isFinite) ? numbers : null;
  }
  const colorMatch = trimmed.match(/^CGColor\(\[([^\]]*)\]\)$/);
  if (colorMatch) {
    const numbers = colorMatch[1]
      .split(",")
      .map((item) => Number(item.trim()));
    return numbers.every(Number.isFinite) ? numbers : null;
  }
  const pointMatch = trimmed.match(
    /^(?:CGPoint|CGSize)\([^0-9+.-]*([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)[^0-9+.-]+([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)\)$/i
  );
  return pointMatch ? [Number(pointMatch[1]), Number(pointMatch[2])] : null;
}

function addVector(target, key, value) {
  const vector = parseNumericVector(value);
  if (!vector) return;
  vector.forEach((component, index) => {
    target.set(
      vector.length === 1 ? key : `${key}[${index}]`,
      component
    );
  });
}

function numericChannels(snapshot) {
  if (!snapshot || typeof snapshot !== "object") return new Map();
  const cached = numericChannelCache.get(snapshot);
  if (cached) return cached;
  const channels = new Map();
  const model = snapshot?.model;
  for (const filter of model?.filters ?? []) {
    const prefix = `filter|${filter.path}|${filter.location}|${filter.name}`;
    for (const input of filter.inputs ?? []) {
      addVector(channels, `${prefix}|${input.key}`, input.value);
    }
  }
  for (const effect of model?.effects ?? []) {
    const prefix = `effect|${effect.path}|${effect.effectClass}`;
    addVector(channels, `${prefix}|layerOpacity`, effect.layerOpacity);
    for (const input of effect.inputs ?? []) {
      addVector(channels, `${prefix}|${input.key}`, input.value);
    }
  }
  const layerKeys = [
    "frameX",
    "frameY",
    "frameWidth",
    "frameHeight",
    "boundsX",
    "boundsY",
    "boundsWidth",
    "boundsHeight",
    "positionX",
    "positionY",
    "zPosition",
    "opacity",
    "cornerRadius",
  ];
  for (const layer of snapshot?.modelLayers ?? []) {
    const prefix = `layer|${layer.path}|${layer.layerClass}`;
    for (const key of layerKeys) {
      addVector(channels, `${prefix}|${key}`, layer[key]);
    }
    for (const [key, vector] of [
      ["transform", layer.transform],
      ["sublayerTransform", layer.sublayerTransform],
      ["affineTransform", layer.affineTransform],
    ]) {
      (vector ?? []).forEach((value, index) => {
        addVector(channels, `${prefix}|${key}[${index}]`, value);
      });
    }
  }
  numericChannelCache.set(snapshot, channels);
  return channels;
}

function endpointSample(capture) {
  const phase = capture.direction === "Insertion" ? "settled" : "preflight";
  return (capture.samples ?? []).find((sample) => sample.phase === phase)
    ?? null;
}

function matchingSample(capture, requestedProgress) {
  return (capture.samples ?? []).find(
    (sample) =>
      sample.phase === "sample"
      && Math.abs(sample.requestedProgress - requestedProgress) < 1e-9
  ) ?? null;
}

function channelRange(capture, channel) {
  const values = (capture.samples ?? [])
    .map((sample) => numericChannels(sample.snapshot).get(channel))
    .filter(Number.isFinite);
  if (values.length < 2) return null;
  return {
    minimum: Math.min(...values),
    maximum: Math.max(...values),
  };
}

function rangeNormalized(value, range) {
  if (!range) return null;
  const span = range.maximum - range.minimum;
  if (span < 1e-3) return null;
  return (value - range.minimum) / span;
}

function curveForCapture(capture) {
  const samples = [];
  for (const sample of capture.samples ?? []) {
    const progress = glassProgress(sample.snapshot);
    if (progress === null) continue;
    samples.push({
      progress,
      channels: numericChannels(sample.snapshot),
    });
  }
  samples.sort((left, right) => left.progress - right.progress);
  const deduplicated = [];
  for (const sample of samples) {
    const previous = deduplicated.at(-1);
    if (previous && Math.abs(previous.progress - sample.progress) < 1e-5) {
      previous.channels = sample.channels;
    } else {
      deduplicated.push(sample);
    }
  }
  return deduplicated;
}

function interpolateCurve(curve, channel, progress) {
  const points = curve
    .filter((sample) => sample.channels.has(channel))
    .map((sample) => ({
      progress: sample.progress,
      value: sample.channels.get(channel),
    }));
  if (points.length < 2) return null;
  if (
    progress < points[0].progress - 1e-6
    || progress > points.at(-1).progress + 1e-6
  ) {
    return null;
  }
  const exact = points.find(
    (point) => Math.abs(point.progress - progress) < 1e-6
  );
  if (exact) return exact.value;
  for (let index = 1; index < points.length; index += 1) {
    const left = points[index - 1];
    const right = points[index];
    if (left.progress <= progress && progress <= right.progress) {
      const span = right.progress - left.progress;
      if (span < 1e-9) return right.value;
      const fraction = (progress - left.progress) / span;
      return left.value + (right.value - left.value) * fraction;
    }
  }
  return null;
}

function normalizedValue(curve, channel, progress) {
  const points = curve
    .filter((sample) => sample.channels.has(channel))
    .map((sample) => ({
      progress: sample.progress,
      value: sample.channels.get(channel),
    }));
  if (points.length < 2) return null;
  const low = points[0].value;
  const high = points.at(-1).value;
  const span = high - low;
  if (Math.abs(span) < 1e-3) return null;
  const value = interpolateCurve(curve, channel, progress);
  return value === null ? null : (value - low) / span;
}

const expectedKeys = new Set();
for (const material of expectedMaterials) {
  for (const requestedMain of expectedMain) {
    for (const appearance of expectedAppearances) {
      for (const backdrop of expectedBackdrops) {
        for (const tint of expectedTints) {
          for (const direction of expectedDirections) {
            expectedKeys.add([
              material,
              requestedMain ? "main" : "flat",
              appearance,
              backdrop,
              tint,
              direction,
            ].join("|"));
          }
        }
      }
    }
  }
}

const actualKeys = transitions.map(captureKey);
const duplicateKeys = actualKeys.filter(
  (key, index) => actualKeys.indexOf(key) !== index
);
const missingKeys = [...expectedKeys].filter(
  (key) => !actualKeys.includes(key)
);
const unexpectedKeys = actualKeys.filter((key) => !expectedKeys.has(key));
const contextFailures = transitions
  .filter((capture) => {
    const context = capture.context ?? {};
    const effective = String(context.effectiveAppearance ?? "").toLowerCase();
    const appearanceMatches =
      context.requestedAppearance === "Light"
        ? effective.includes("aqua") && !effective.includes("dark")
        : context.requestedAppearance === "Dark"
          ? effective.includes("dark")
          : false;
    return (
      context.actualMain !== context.requestedMain
      || context.actualKey !== false
      || !appearanceMatches
      || !expectedBackdrops.includes(context.backdrop)
      || capture.samples?.length !== 9
    );
  })
  .map(captureKey);

const grouped = new Map();
for (const capture of transitions) {
  const key = comparisonKey(capture);
  if (!grouped.has(key)) grouped.set(key, []);
  grouped.get(key).push(capture);
}

const topologyMismatches = [];
const endpointMismatches = [];
const endpointAxisDifferences = {
  appearance: [],
  backdrop: [],
};
const interpolationDifferences = [];
let comparedNumericChannels = 0;
let normalizedMaximumDifference = 0;
let rawMaximumDifference = 0;
const commonProgresses = [0.125, 0.25, 0.5, 0.75, 0.875];

function compareEndpointPair(group, axis, leftCapture, rightCapture) {
  const left = numericChannels(endpointSample(leftCapture)?.snapshot);
  const right = numericChannels(endpointSample(rightCapture)?.snapshot);
  const differences = [...left.keys()]
    .filter((channel) => right.has(channel))
    .map((channel) => ({
      channel,
      difference: Math.abs(left.get(channel) - right.get(channel)),
    }))
    .filter((entry) => entry.difference > 1e-7)
    .sort((first, second) => second.difference - first.difference);
  endpointAxisDifferences[axis].push({
    group,
    pair: `${environmentKey(leftCapture)} ↔ ${environmentKey(rightCapture)}`,
    differingNumericChannels: differences.length,
    maximumDifference: differences[0]?.difference ?? 0,
    worstChannels: differences.slice(0, 12),
  });
}

for (const [key, captures] of grouped) {
  if (captures.length !== 4) continue;
  const environments = new Set(captures.map(environmentKey));
  if (environments.size !== 4) continue;

  const sampleMaps = captures.map((capture) => new Map(
    (capture.samples ?? []).map((sample) => [sampleKey(sample), sample])
  ));
  const sharedSampleKeys = [...sampleMaps[0].keys()].filter(
    (sample) => sampleMaps.every((map) => map.has(sample))
  );
  for (const sample of sharedSampleKeys) {
    const signatures = sampleMaps.map((map) =>
      topologySignature(map.get(sample).snapshot)
    );
    if (new Set(signatures).size !== 1) {
      topologyMismatches.push({
        group: key,
        sample,
        environments: captures.map(environmentKey),
      });
    }
  }

  const byEnvironment = new Map(
    captures.map((capture) => [environmentKey(capture), capture])
  );
  compareEndpointPair(
    key,
    "backdrop",
    byEnvironment.get("Light|Light"),
    byEnvironment.get("Light|Dark")
  );
  compareEndpointPair(
    key,
    "backdrop",
    byEnvironment.get("Dark|Light"),
    byEnvironment.get("Dark|Dark")
  );
  compareEndpointPair(
    key,
    "appearance",
    byEnvironment.get("Light|Light"),
    byEnvironment.get("Dark|Light")
  );
  compareEndpointPair(
    key,
    "appearance",
    byEnvironment.get("Light|Dark"),
    byEnvironment.get("Dark|Dark")
  );

  const endpointSamples = captures.map(endpointSample);
  const endpointSignatures = endpointSamples.map((sample) =>
    modelValueSignature(sample?.snapshot)
  );
  if (new Set(endpointSignatures).size !== 1) {
    endpointMismatches.push({
      group: key,
      environments: captures.map(environmentKey),
    });
  }

  const channelSets = captures.map((capture) => new Set(
    (capture.samples ?? []).flatMap(
      (sample) => [...numericChannels(sample.snapshot).keys()]
    )
  ));
  const commonChannels = [...channelSets[0]].filter(
    (channel) => channelSets.every((set) => set.has(channel))
  );
  const curves = captures.map(curveForCapture);
  for (const channel of commonChannels) {
    let channelNormalizedMaximum = 0;
    let channelRawMaximum = 0;
    let comparisonCount = 0;
    for (const progress of commonProgresses) {
      const matchedSamples = captures.map((capture) =>
        matchingSample(capture, progress)
      );
      const rawValues = matchedSamples.map((sample) => {
        return sample
          ? numericChannels(sample.snapshot).get(channel) ?? null
          : null;
      });
      if (rawValues.every((value) => value !== null)) {
        channelRawMaximum = Math.max(
          channelRawMaximum,
          Math.max(...rawValues) - Math.min(...rawValues)
        );
      }
      const normalized = matchedSamples.map((sample, index) => {
        if (!sample) return null;
        const actualProgress = glassProgress(sample.snapshot);
        return actualProgress === null
          ? null
          : normalizedValue(curves[index], channel, actualProgress);
      });
      if (normalized.every((value) => value !== null)) {
        channelNormalizedMaximum = Math.max(
          channelNormalizedMaximum,
          Math.max(...normalized) - Math.min(...normalized)
        );
        comparisonCount += 1;
      }
    }
    if (comparisonCount === 0) continue;
    comparedNumericChannels += 1;
    normalizedMaximumDifference = Math.max(
      normalizedMaximumDifference,
      channelNormalizedMaximum
    );
    rawMaximumDifference = Math.max(
      rawMaximumDifference,
      channelRawMaximum
    );
    interpolationDifferences.push({
      group: key,
      channel,
      normalizedMaximumDifference: channelNormalizedMaximum,
      rawMaximumDifference: channelRawMaximum,
    });
  }
}

interpolationDifferences.sort(
  (left, right) =>
    right.normalizedMaximumDifference - left.normalizedMaximumDifference
);

let tintSamples = 0;
let tintSquaredMaximumResidual = 0;
let tintSquaredSumOfSquares = 0;
const tintResidualByEnvironment = {};
for (const capture of transitions) {
  const sourceAlpha = tintAlpha(capture.context?.tint);
  if (sourceAlpha === null) continue;
  const environment = environmentKey(capture);
  tintResidualByEnvironment[environment] ??= {
    samples: 0,
    maximumResidual: 0,
    sumOfSquares: 0,
  };
  for (const sample of capture.samples ?? []) {
    const progress = glassProgress(sample.snapshot);
    const matrix = tintMatrix(sample.snapshot);
    if (progress === null || !matrix) continue;
    const residual = matrix[18] - sourceAlpha * progress * progress;
    const absolute = Math.abs(residual);
    tintSamples += 1;
    tintSquaredMaximumResidual = Math.max(
      tintSquaredMaximumResidual,
      absolute
    );
    tintSquaredSumOfSquares += residual * residual;
    tintResidualByEnvironment[environment].samples += 1;
    tintResidualByEnvironment[environment].maximumResidual = Math.max(
      tintResidualByEnvironment[environment].maximumResidual,
      absolute
    );
    tintResidualByEnvironment[environment].sumOfSquares +=
      residual * residual;
  }
}
for (const environment of Object.values(tintResidualByEnvironment)) {
  environment.rmsResidual = Math.sqrt(
    environment.sumOfSquares / Math.max(environment.samples, 1)
  );
  delete environment.sumOfSquares;
}

function summarizeEndpointAxis(entries) {
  const differing = entries.filter(
    (entry) => entry.differingNumericChannels > 0
  );
  return {
    comparedPairs: entries.length,
    differingPairs: differing.length,
    maximumDifference: Math.max(
      0,
      ...entries.map((entry) => entry.maximumDifference)
    ),
    worstPairs: differing
      .sort((left, right) => right.maximumDifference - left.maximumDifference)
      .slice(0, 24),
  };
}

const validationFailures = [];
if (transitions.length !== 64) {
  validationFailures.push(
    `Expected 64 transitions, found ${transitions.length}`
  );
}
if (missingKeys.length > 0) {
  validationFailures.push(`Missing ${missingKeys.length} dimension cells`);
}
if (unexpectedKeys.length > 0) {
  validationFailures.push(
    `Found ${unexpectedKeys.length} unexpected dimension cells`
  );
}
if (duplicateKeys.length > 0) {
  validationFailures.push(
    `Found ${duplicateKeys.length} duplicate dimension cells`
  );
}
if (contextFailures.length > 0) {
  validationFailures.push(
    `${contextFailures.length} captures rejected their requested context`
  );
}
if (
  transitions.reduce(
    (sum, capture) => sum + (capture.samples?.length ?? 0),
    0
  ) !== 576
) {
  validationFailures.push("Expected 576 total samples");
}

const summary = {
  source: inputPath,
  validation: {
    passed: validationFailures.length === 0,
    failures: validationFailures,
    missingKeys,
    unexpectedKeys,
    duplicateKeys: [...new Set(duplicateKeys)],
    contextFailures,
  },
  environment: {
    operatingSystem: document.operatingSystem,
    capturedAt: document.capturedAt,
    context: document.context,
  },
  counts: {
    transitions: transitions.length,
    samples: transitions.reduce(
      (sum, capture) => sum + (capture.samples?.length ?? 0),
      0
    ),
    comparisonGroups: grouped.size,
  },
  environmentSensitivity: {
    topology: {
      comparisonGroups: grouped.size,
      mismatches: topologyMismatches.length,
      firstMismatches: topologyMismatches.slice(0, 20),
    },
    modelEndpoints: {
      comparisonGroups: grouped.size,
      groupsWithDifferences: endpointMismatches.length,
      differingGroups: endpointMismatches,
      byAxis: {
        appearance: summarizeEndpointAxis(
          endpointAxisDifferences.appearance
        ),
        backdrop: summarizeEndpointAxis(endpointAxisDifferences.backdrop),
      },
    },
    normalizedInterpolation: {
      comparedNumericChannels,
      commonProgresses,
      maximumEnvironmentDifference: normalizedMaximumDifference,
      rawMaximumEnvironmentDifference: rawMaximumDifference,
      worstChannels: interpolationDifferences.slice(0, 40),
    },
  },
  tint: {
    alphaEqualsSourceAlphaTimesGSquared: {
      samples: tintSamples,
      maximumResidual: tintSquaredMaximumResidual,
      rmsResidual: Math.sqrt(
        tintSquaredSumOfSquares / Math.max(tintSamples, 1)
      ),
      byEnvironment: tintResidualByEnvironment,
    },
  },
};

console.log(JSON.stringify(summary, null, 2));
if (validationFailures.length > 0) process.exitCode = 1;
