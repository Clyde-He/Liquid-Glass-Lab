import { spawnSync } from "node:child_process";
import { createReadStream, createWriteStream } from "node:fs";
import { access, cp, mkdir, readFile, readdir, rename, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { createGzip, gunzip } from "node:zlib";
import { cellKey, LEGACY_CELL_FIELDS } from "./cell.mjs";
import { catalogFromArchive } from "./catalog.mjs";
import {
  dynamicLifecycleProblems, dynamicPairingProblems,
} from "./dynamic-contract.mjs";
import { compareStableDynamicRuns } from "./dynamic-equivalence.mjs";
import {
  projectStyleSample, staticTopologySignature,
} from "./snapshot-projections.mjs";
import { tintDocumentGateProblems } from "./tint-compare.mjs";
import { samplingProblems, comparableSampling } from "./sampling-coverage.mjs";
import { compareTransparency, transparencyProblems } from "./transparency.mjs";

export { compareTransparency } from "./transparency.mjs";

export const ARCHIVE_FILES = {
  capture: "capture.json",
  static: "static.json",
  dynamic: "dynamic.json",
  tintSweep: "tint-parameterization-sweep.json",
  tintFocused: "tint-parameterization-focused-phase-2b.json",
  tintHue: "tint-parameterization-hue-phase-2c.json",
  tintSync: "tint-sync-resolution.json",
  tintWideGamut: "tint-wide-gamut-model.json",
  semantic: "semantic-usage-trees.json",
};

const TINT_DOCUMENTS = [
  ["tint.parameterization.sweep", "tintSweep"],
  ["tint.parameterization.focused-2b", "tintFocused"],
  ["tint.parameterization.hue-2c", "tintHue"],
  ["tint.sync-resolution", "tintSync"],
  ["tint.wide-gamut", "tintWideGamut"],
];

const gunzipAsync = promisify(gunzip);
const COMPRESSED_ARCHIVE_FILES = new Set(
  Object.values(ARCHIVE_FILES).filter((file) => file !== ARCHIVE_FILES.capture)
);

export function platformFromCapture(capture) {
  const description = capture?.operatingSystem ?? "";
  const version = /Version ([0-9.]+)/.exec(description)?.[1] ?? null;
  const build = /Build ([^)]+)/.exec(description)?.[1] ?? null;
  const major = Number.parseInt(version, 10);
  return {
    product: "macOS",
    version,
    major: Number.isInteger(major) ? major : null,
    build,
    architecture: capture?.architecture ?? null,
    displaySignature: capture?.displaySignature ?? null,
  };
}

async function readJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

/** Reads one logical archive document from plain capture JSON or accepted gzip storage. */
export async function readArchiveJSON(directory, file) {
  try {
    return await readJSON(path.join(directory, file));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const compressed = path.join(directory, `${file}.gz`);
  return JSON.parse((await gunzipAsync(await readFile(compressed))).toString("utf8"));
}

export async function readArchive(directory) {
  const capture = await readArchiveJSON(directory, ARCHIVE_FILES.capture);
  const platform = platformFromCapture(capture);
  const documents = { capture };
  const required = Object.entries(ARCHIVE_FILES).filter(
    ([name]) => !["capture", "semantic"].includes(name)
  );
  await Promise.all(required.map(async ([name, file]) => {
    documents[name] = await readArchiveJSON(directory, file);
  }));
  if (platform.major >= 27) {
    documents.semantic = await readArchiveJSON(directory, ARCHIVE_FILES.semantic);
  } else {
    documents.semantic = null;
  }
  return { directory, ...documents, platform };
}

function finite(value) {
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(finite);
  if (value && typeof value === "object") return Object.values(value).every(finite);
  return true;
}

function matrixIsFinite(matrix) {
  return Array.isArray(matrix) && matrix.length === 20 && matrix.every(Number.isFinite);
}

function typedValueProblems(value, at = "value") {
  const problems = [];
  function typed(node, label) {
    const type = node?.type;
    const data = node?.[type];
    const valid = {
      number: () => Number.isFinite(data),
      boolean: () => typeof data === "boolean",
      string: () => typeof data === "string",
      opaque: () => typeof node.opaqueType === "string",
      matrix: () => Array.isArray(data?.coefficients)
        && data.coefficients.length === 20 && data.coefficients.every(Number.isFinite),
      color: () => Array.isArray(data?.components) && data.components.every(Number.isFinite),
      point: () => ["x", "y"].every((key) => Number.isFinite(data?.[key])),
      size: () => ["x", "y"].every((key) => Number.isFinite(data?.[key])),
      rect: () => ["x", "y", "width", "height"].every((key) => Number.isFinite(data?.[key])),
      array: () => Array.isArray(data),
      dictionary: () => data && typeof data === "object" && !Array.isArray(data),
    }[type];
    if (!valid || !valid()) problems.push(`${label}: invalid typed ${type}`);
    else if (type === "array" || type === "dictionary") {
      Object.entries(data).forEach(([key, child]) => typed(child, `${label}.${key}`));
    }
  }
  function visit(node, label) {
    if (!node || typeof node !== "object") return;
    if (Object.hasOwn(node, "state") && Object.hasOwn(node, "attributes")) {
      if (!["value", "nil", "unreadable"].includes(node.state)
          || (node.state === "value") !== Object.hasOwn(node, "value")) {
        problems.push(`${label}: invalid property state`);
      } else if (node.state === "value") typed(node.value, `${label}.value`);
    }
    Object.entries(node).forEach(([key, child]) => visit(child, `${label}.${key}`));
  }
  visit(value, at);
  return problems;
}

function cellProblems(cell, label) {
  const problems = [];
  const missing = [...LEGACY_CELL_FIELDS, "shortSide"]
    .filter((field) => !Object.hasOwn(cell ?? {}, field));
  if (missing.length) problems.push(`${label}: cell is missing ${missing.join(", ")}`);
  if (!finite(cell)) problems.push(`${label}: cell contains a non-finite value`);
  if (Number.isFinite(cell?.width) && Number.isFinite(cell?.height)
      && cell.shortSide !== Math.min(cell.width, cell.height)) {
    problems.push(`${label}: shortSide disagrees with width and height`);
  }
  return problems;
}

export function validateStaticDocument(
  document, { requireConsumerCells = true } = {},
) {
  const problems = [];
  if (document?.schemaVersion !== 2 || !Array.isArray(document.observations)) {
    return ["static.json must be a schema-2 observation document"];
  }
  if (document.observations.length === 0) problems.push("static.json has no observations");
  const observations = new Map();
  for (const [index, observation] of document.observations.entries()) {
    problems.push(...cellProblems(observation.cell, `static observation ${index}`));
    const key = cellKey(observation.cell);
    if (observations.has(key)) problems.push(`static observation ${index} duplicates ${key}`);
    observations.set(key, observation);
    const snapshot = observation.snapshot;
    problems.push(...typedValueProblems(snapshot, `static observation ${index}`));
    if (!snapshot || !Number.isFinite(snapshot.shortSide)
        || !Array.isArray(snapshot.layers) || snapshot.layers.length === 0
        || !Array.isArray(snapshot.passes) || !finite(snapshot)) {
      problems.push(`static observation ${index} has no complete finite Snapshot`);
      continue;
    }
    if (snapshot.shortSide !== observation.cell.shortSide) {
      problems.push(`static observation ${index} Snapshot shortSide disagrees with its cell`);
    }
    const layerPaths = new Set(snapshot.layers.map(({ path }) => path));
    if (layerPaths.size !== snapshot.layers.length) {
      problems.push(`static observation ${index} duplicates a layer path`);
    }
    const passIDs = new Set(snapshot.passes.map(({ id }) => id));
    if (passIDs.size !== snapshot.passes.length) {
      problems.push(`static observation ${index} duplicates a pass ID`);
    }
    for (const [owner, properties] of [
      ...snapshot.layers.map((layer, layerIndex) => [
        `layer ${layerIndex}`, layer.properties,
      ]),
      ...snapshot.passes.map((pass, passIndex) => [
        `pass ${passIndex}`, pass.properties,
      ]),
    ]) {
      for (const [name, property] of Object.entries(properties ?? {})) {
        if (!["value", "nil", "unreadable"].includes(property?.state)
            || (property.state === "value") !== Object.hasOwn(property, "value")) {
          problems.push(
            `static observation ${index} ${owner} property ${name} has invalid state`
          );
        }
      }
    }
  }

  if (!Array.isArray(document.consumerCells)) {
    problems.push("static.json has no Consumer cell array");
    return problems;
  }
  if (requireConsumerCells && document.consumerCells.length === 0) {
    problems.push("static.json has no Consumer cells");
    return problems;
  }
  const consumerKeys = new Set();
  for (const [index, cell] of document.consumerCells.entries()) {
    problems.push(...cellProblems(cell, `Consumer cell ${index}`));
    const key = cellKey(cell);
    if (consumerKeys.has(key)) problems.push(`Consumer cell ${index} duplicates ${key}`);
    consumerKeys.add(key);
    const observation = observations.get(key);
    if (!observation) problems.push(`Consumer cell ${index} has no Static observation`);
    else if (!projectStyleSample(observation.snapshot)) {
      problems.push(`Consumer cell ${index} cannot project a complete supported style sample`);
    }
  }
  return problems;
}

function captureProblems(archive) {
  const problems = transparencyProblems(archive.capture?.transparency);
  const canonical27 = archive.platform.major === 27
    && archive.capture?.transparency?.control === "processOverridePerObservation";
  if (archive.platform.major !== 27 && archive.capture?.transparency !== undefined) {
    problems.push("Glass transparency provenance is supported only on macOS 27");
  }
  if (canonical27) {
    for (const [index, observation] of (archive.static?.observations ?? []).entries()) {
      if (Object.hasOwn(observation, "raw")) {
        problems.push(`Static observation ${index}: duplicate raw payload is forbidden`);
      }
      for (const layer of observation.snapshot?.layers ?? []) {
        for (const field of [
          "position", "anchorPoint", "zPosition", "contentsScale",
          "transform", "sublayerTransform", "affineTransform", "properties",
        ]) {
          if (!Object.hasOwn(layer, field)) {
            problems.push(`Static observation ${index}: layer ${layer.path} lacks ${field}`);
          }
        }
        if (layer.layerClass !== "CABackdropLayer") continue;
        const scale = layer.properties?.scale;
        if (scale?.state !== "value" || scale.value?.type !== "number"
            || !Number.isFinite(scale.value.number) || scale.value.number < 0) {
          problems.push(`Static observation ${index}: missing readable finite backdrop scale at ${layer.path}`);
        } else if ([1, 2].includes(observation.cell?.variant)
            && observation.cell?.subvariant == null && scale.value.number <= 0) {
          problems.push(`Static observation ${index}: product-reachable backdrop scale is not positive at ${layer.path}`);
        }
      }
    }
  }
  if (archive.capture?.schemaVersion !== 2 || archive.platform.major === null
      || !archive.platform.build || !archive.platform.architecture
      || !archive.platform.displaySignature || !archive.capture.capturedAt) {
    problems.push("capture.json lacks schema-2 OS/build/architecture/display provenance");
  }
  return problems;
}

export function validateCaptureDocument(capture, staticDocument = null) {
  return captureProblems({
    capture,
    static: staticDocument,
    platform: platformFromCapture(capture),
  });
}

function coordinateCoverageProblems(archive) {
  const problems = [];
  const canonical27 = archive.platform.major === 27
    && archive.capture?.transparency?.control === "processOverridePerObservation";
  const expectedStatic = canonical27 ? 1_750 : 776;
  if (archive.static?.observations?.length !== expectedStatic) {
    problems.push(`static.json must contain ${expectedStatic} observations; got ${archive.static?.observations?.length ?? 0}`);
  }
  const cells = [
    ...(archive.static?.observations ?? []).map(({ cell }) => cell),
    ...(archive.static?.consumerCells ?? []),
    ...(archive.dynamic?.runs ?? []).map(({ cell }) => cell),
  ];
  if (canonical27) {
    if (cells.some((cell) => !Number.isFinite(cell?.glassAmount)
        || cell.glassAmount < 0 || cell.glassAmount > 1)) {
      problems.push("canonical macOS 27 coordinates require glassAmount in 0...1");
    }
    if ((archive.static?.consumerCells ?? []).some(({ glassAmount }) => glassAmount !== 0.5)) {
      problems.push("Consumer cells must remain the macOS 27 0.5 baseline projection");
    }
  } else if (archive.platform.major !== 27
      && cells.some((cell) => Object.hasOwn(cell ?? {}, "glassAmount"))) {
    problems.push("glassAmount must be absent outside macOS 27");
  }
  return problems;
}

function catalogProblems(archive) {
  try {
    catalogFromArchive(archive);
    return [];
  } catch (error) {
    return [`Catalog projection failed: ${error.message}`];
  }
}

export async function admitCoreArchive(directory) {
  let archive;
  try {
    const [capture, staticDocument, dynamic] = await Promise.all([
      readArchiveJSON(directory, ARCHIVE_FILES.capture),
      readArchiveJSON(directory, ARCHIVE_FILES.static),
      readArchiveJSON(directory, ARCHIVE_FILES.dynamic),
    ]);
    archive = {
      directory, capture, static: staticDocument, dynamic,
      platform: platformFromCapture(capture),
    };
  } catch (error) {
    throw new Error(`cannot read Golden Core at ${directory}: ${error.message}`);
  }
  const problems = [
    ...captureProblems(archive),
    ...coordinateCoverageProblems(archive),
    ...validateStaticDocument(archive.static),
    ...validateDynamic(archive),
    ...catalogProblems(archive),
  ];
  if (problems.length) throw new Error(`invalid Golden Core:\n- ${problems.join("\n- ")}`);
  return archive;
}

export function validateDynamicDocument(
  document, capture, {
    expectedRuns,
    requirePlanCardinality = expectedRuns === undefined,
  } = {},
) {
  const platform = platformFromCapture(capture);
  const problems = [];
  const runs = document?.runs;
  if (document?.schemaVersion !== 2 || !Array.isArray(runs)) {
    return ["dynamic.json must be a schema-2 run document"];
  }
  const canonical27 = platform.major === 27
    && capture?.transparency?.control === "processOverridePerObservation";
  const requiredRuns = expectedRuns ?? (canonical27 ? 273 : 104);
  if (runs.length !== requiredRuns) {
    problems.push(`dynamic.json must contain ${requiredRuns} runs; got ${runs.length}`);
  }
  for (const [index, run] of runs.entries()) {
    problems.push(...cellProblems(run.cell, `Dynamic run ${index}`));
    if (run.accepted !== true || !Number.isFinite(run.maximumAttachedAnimationDuration)) {
      problems.push(`Dynamic run ${index} was not accepted or has no finite duration`);
    }
    problems.push(...dynamicLifecycleProblems(run, index));
    if (canonical27) {
      if (!Number.isFinite(run.samplingDuration) || run.samplingDuration <= 0
          || !run.context || !["Linear", "System Default"].includes(run.animationMode)) {
        problems.push(`Dynamic run ${index} lacks its sampling/context contract`);
      }
      for (const [sampleIndex, sample] of (run.samples ?? []).entries()) {
        if (!sample.snapshot?.model || !Array.isArray(sample.snapshot.modelLayers)
            || !Array.isArray(sample.snapshot.animations)) {
          problems.push(`Dynamic run ${index} sample ${sampleIndex} lacks its native snapshot`);
        }
        if (["raw", "filters", "effects", "layerLines", "backdropSampling"]
          .some((field) => Object.hasOwn(sample, field))) {
          problems.push(`Dynamic run ${index} sample ${sampleIndex} duplicates a snapshot projection`);
        }
      }
      problems.push(...samplingProblems(run.samples, `Dynamic run ${index}`));
    }
    if (!finite(run.samples)) problems.push(`Dynamic run ${index} contains non-finite samples`);
  }
  problems.push(...dynamicPairingProblems(runs, "Dynamic", {
    enforceCardinality: requirePlanCardinality && !canonical27,
  }));
  return problems;
}

function validateDynamic(archive) {
  return validateDynamicDocument(archive.dynamic, archive.capture);
}

function validateTint(id, document) {
  const problems = tintDocumentGateProblems(document, id);
  if (!Array.isArray(document?.rows) || document.rows.length === 0) {
    return [...problems, `${id} has no rows`];
  }
  const identities = new Set();
  for (const [index, row] of document.rows.entries()) {
    const cell = row.cell ?? {};
    const identity = JSON.stringify([
      row.colorID, cell.isLightAppearance, cell.isClear, cell.hasMainParticipation,
    ]);
    if (identities.has(identity)) problems.push(`${id}: duplicate row ${index}`);
    identities.add(identity);
    if (id.startsWith("tint.parameterization.")) {
      if (!matrixIsFinite(row.matrix)) problems.push(`${id}: row ${index} has no finite matrix`);
    } else if (!matrixIsFinite(row.flushMatrix) || !matrixIsFinite(row.settledMatrix)
        || !Number.isFinite(row.maximumDifference)
        || row.passed !== true || row.pairedProofAtFlush !== true
        || row.pairedProofWhenSettled !== true) {
      problems.push(`${id}: row ${index} failed paired finite-matrix proof`);
    }
  }
  if (id.startsWith("tint.parameterization.")) {
    const colors = document.plan?.colors ?? [];
    const expected = new Set(colors.flatMap(({ id }) => [false, true].flatMap((appearance) =>
      [false, true].flatMap((clear) => [false, true].map((main) =>
        JSON.stringify([id, appearance, clear, main]))))));
    if (identities.size !== expected.size
        || [...identities].some((identity) => !expected.has(identity))) {
      problems.push(`${id}: observed color/cell IDs differ from the plan`);
    }
    const planned = colors.length;
    if (Number.isInteger(planned) && document.rows.length !== planned * 8) {
      problems.push(`${id}: ${document.rows.length} rows do not cover ${planned} colors × 8 cells`);
    }
  } else {
    if (document?.formatVersion !== 2) {
      problems.push(`${id}: formatVersion is not 2`);
    }
    const planned = document?.plannedColorIDs;
    const plannedSet = new Set(planned ?? []);
    if (!Array.isArray(planned) || planned.length === 0
        || plannedSet.size !== planned.length
        || !planned.every((value) => typeof value === "string" && value.length > 0)) {
      problems.push(`${id}: plannedColorIDs is missing or invalid`);
    } else {
      const observed = new Set(document.rows.map(({ colorID }) => colorID));
      if (observed.size !== plannedSet.size
          || [...observed].some((colorID) => !plannedSet.has(colorID))) {
        problems.push(`${id}: observed color IDs do not match plannedColorIDs`);
      }
      for (const colorID of planned) {
        const colorRows = document.rows.filter((row) => row.colorID === colorID);
        const cells = new Set(colorRows.map(({ cell }) => JSON.stringify([
          cell?.isLightAppearance, cell?.isClear, cell?.hasMainParticipation,
        ])));
        if (colorRows.length !== 8 || cells.size !== 8) {
          problems.push(`${id}: ${colorID} does not cover 8 unique cells`);
        }
      }
      const timingIDs = document?.timings?.map(({ colorID }) => colorID) ?? [];
      if (timingIDs.length !== planned.length
          || new Set(timingIDs).size !== planned.length
          || timingIDs.some((colorID) => !plannedSet.has(colorID))) {
        problems.push(`${id}: timings do not cover plannedColorIDs exactly once`);
      }
    }
  }
  return problems;
}

function validateSemantic(archive) {
  if (archive.platform.major < 27) return [];
  const document = archive.semantic;
  const entries = document?.entries;
  const context = document?.context ?? {};
  const problems = [];
  if (document?.formatVersion !== 2 || !Array.isArray(entries) || entries.length !== 48) {
    return ["semantic-usage-trees.json must contain 48 schema-2 entries"];
  }
  if (context.hostType !== "Panel" || context.glassWidth !== 480
      || context.glassHeight !== 200 || context.cornerRadius !== 16) {
    problems.push("Semantic capture context is not the canonical Panel 480×200 context");
  }
  const identities = new Set();
  for (const [index, entry] of entries.entries()) {
    identities.add(JSON.stringify([entry.roleTag, entry.requestedMain]));
    if (entry.actualKey !== false || entry.actualMain !== entry.requestedMain
        || typeof entry.isAvailable !== "boolean") {
      problems.push(`Semantic entry ${index} has invalid participation or availability`);
    } else if (entry.isAvailable && (!Array.isArray(entry.snapshot?.layerLines)
        || entry.snapshot.layerLines.length === 0
        || !Array.isArray(entry.snapshot?.filters)
        || !Array.isArray(entry.snapshot?.effects))) {
      problems.push(`Semantic entry ${index} has no complete usage tree`);
    } else if (!entry.isAvailable && entry.snapshot != null) {
      problems.push(`Semantic entry ${index} is unavailable but carries a Snapshot`);
    }
  }
  if (identities.size !== 48) problems.push("Semantic role/participation coordinates are incomplete");
  if (archive.platform.major >= 27 && entries.some(({ isAvailable }) => !isAvailable)) {
    problems.push("macOS 27+ Semantic capture contains unavailable roles");
  }
  if (archive.platform.major === 27
      && archive.capture?.transparency?.control === "processOverridePerObservation") {
    problems.push(...samplingProblems(entries, "Semantic"));
  }
  return problems;
}

function embeddedOSProblems(archive) {
  const problems = [];
  for (const [name, document] of [
    ...TINT_DOCUMENTS.map(([id, key]) => [id, archive[key]]),
    ["semantic.usage-trees", archive.semantic],
  ]) {
    if (!document) continue;
    if (archive.platform.major !== 27
        && (document.transparency !== undefined
          || document.capture?.transparency !== undefined
          || document.environment?.glassAmount != null)) {
      problems.push(`${name} contains macOS 27-only transparency metadata`);
    }
    if (archive.capture.transparency !== undefined
        && !compareTransparency(archive.capture, document).comparable) {
      problems.push(`${name} has missing or different transparency provenance`);
    }
    const baselineAmount = archive.capture?.transparency?.baselineAmount
      ?? archive.capture?.transparency?.amount;
    if (archive.capture.transparency !== undefined
        && name.startsWith("tint.parameterization")
        && document.environment?.glassAmount !== baselineAmount) {
      problems.push(`${name} environment has missing or different Glass amount`);
    }
    if (document?.operatingSystem !== archive.capture.operatingSystem) {
      problems.push(`${name} was not captured on ${archive.capture.operatingSystem}`);
    }
    const display = document?.environment?.displaySignature;
    if (display && display !== archive.capture.displaySignature) {
      problems.push(`${name} was captured on display ${display}, not ${archive.capture.displaySignature}`);
    }
  }
  return problems;
}

export function validateArchive(archive) {
  const problems = [];
  problems.push(...captureProblems(archive));
  problems.push(...coordinateCoverageProblems(archive));
  problems.push(...validateStaticDocument(archive.static));
  problems.push(...validateDynamic(archive));
  problems.push(...catalogProblems(archive));
  for (const [id, key] of TINT_DOCUMENTS) problems.push(...validateTint(id, archive[key]));
  problems.push(...validateSemantic(archive));
  problems.push(...embeddedOSProblems(archive));
  return [...new Set(problems)];
}

export async function admitArchive(directory) {
  let archive;
  try {
    archive = await readArchive(directory);
  } catch (error) {
    throw new Error(`cannot read Golden archive at ${directory}: ${error.message}`);
  }
  const problems = validateArchive(archive);
  if (problems.length) throw new Error(`invalid Golden archive:\n- ${problems.join("\n- ")}`);
  return archive;
}

function countDifferences(left, right, pathName = "", examples = [], options = {}) {
  if (typeof left === "number" && typeof right === "number") {
    if (options.ignoredKeys?.has(pathName.split(".").at(-1))) return 0;
    if (Math.abs(left - right) <= (options.tolerance ?? 0)) return 0;
    if (examples.length < 12) examples.push(pathName || "root");
    return 1;
  }
  if (left === right) return 0;
  if (Array.isArray(left) && Array.isArray(right)) {
    let count = Math.abs(left.length - right.length);
    for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
      count += countDifferences(left[index], right[index], `${pathName}[${index}]`, examples, options);
    }
    if (count && examples.length < 12) examples.push(pathName || "root");
    return count;
  }
  if (left && right && typeof left === "object" && typeof right === "object") {
    let count = 0;
    const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
    for (const key of keys) {
      if (options.ignoredKeys?.has(key)) continue;
      if (options.compareCommonFields
          && (!Object.hasOwn(left, key) || !Object.hasOwn(right, key))) {
        options.coverageGaps?.push(pathName ? `${pathName}.${key}` : key);
        continue;
      }
      count += countDifferences(left[key], right[key], pathName ? `${pathName}.${key}` : key,
        examples, options);
    }
    return count;
  }
  if (examples.length < 12) examples.push(pathName || "root");
  return 1;
}

function valuesNamed(value, target, pathName = "root", entries = {}) {
  if (!value || typeof value !== "object") return entries;
  if (Array.isArray(value)) {
    value.forEach((item, index) => valuesNamed(item, target, `${pathName}[${index}]`, entries));
    return entries;
  }
  for (const [key, child] of Object.entries(value)) {
    const childPath = `${pathName}.${key}`;
    if (key === target) entries[childPath] = child;
    else valuesNamed(child, target, childPath, entries);
  }
  return entries;
}

function compareNamedValues(baseline, candidate, name, section) {
  const examples = [];
  const differences = countDifferences(
    valuesNamed(baseline, name), valuesNamed(candidate, name),
    section, examples, { tolerance: 1e-6 }
  );
  return { differences, examples: [...new Set(examples)].slice(0, 12) };
}

export function compareStaticDocuments(baseline, candidate, {
  compareCommonFields = false,
} = {}) {
  const staticBaseline = new Map(
    baseline.observations.map((observation) => [cellKey(observation.cell), observation])
  );
  const staticCandidate = new Map(
    candidate.observations.map((observation) => [cellKey(observation.cell), observation])
  );
  const staticExamples = [];
  let staticChanged = 0;
  let staticDifferences = 0;
  let volatileChanged = 0;
  let volatileDifferences = 0;
  const volatileExamples = [];
  const coverageGaps = [];
  for (const key of new Set([...staticBaseline.keys(), ...staticCandidate.keys()])) {
    const baselineSnapshot = staticBaseline.get(key)?.snapshot;
    const candidateSnapshot = staticCandidate.get(key)?.snapshot;
    const count = countDifferences(
      baselineSnapshot,
      candidateSnapshot,
      key,
      staticExamples,
      {
        tolerance: 1e-6,
        ignoredKeys: new Set(["inputMaxHeadroom"]),
        compareCommonFields,
        coverageGaps,
      }
    );
    if (count) staticChanged += 1;
    staticDifferences += count;
    const volatileCount = countDifferences(
      Object.fromEntries((baselineSnapshot?.passes ?? []).flatMap((pass) =>
        Object.hasOwn(pass.properties ?? {}, "inputMaxHeadroom")
          ? [[`${pass.id}.inputMaxHeadroom`, pass.properties.inputMaxHeadroom]] : [])),
      Object.fromEntries((candidateSnapshot?.passes ?? []).flatMap((pass) =>
        Object.hasOwn(pass.properties ?? {}, "inputMaxHeadroom")
          ? [[`${pass.id}.inputMaxHeadroom`, pass.properties.inputMaxHeadroom]] : [])),
      key, volatileExamples, { tolerance: 1e-6 }
    );
    if (volatileCount) volatileChanged += 1;
    volatileDifferences += volatileCount;
  }
  const baselineTopology = new Map(
    baseline.observations.map((row) => [
      cellKey(row.cell), staticTopologySignature(row.snapshot),
    ])
  );
  const candidateTopology = new Map(
    candidate.observations.map((row) => [
      cellKey(row.cell), staticTopologySignature(row.snapshot),
    ])
  );
  const topologyChanged = [...new Set([
    ...baselineTopology.keys(), ...candidateTopology.keys(),
  ])].filter((key) => baselineTopology.get(key) !== candidateTopology.get(key)).length;
  return {
    equivalent: staticDifferences === 0 && topologyChanged === 0,
    coverage: {
      complete: coverageGaps.length === 0,
      addedOrMissingFields: coverageGaps.length,
      examples: [...new Set(coverageGaps)].slice(0, 12),
    },
    changedObservations: staticChanged,
    changedFields: staticDifferences,
    topologyChangedObservations: topologyChanged,
    examples: [...new Set(staticExamples)].slice(0, 12),
    volatile: {
      inputMaxHeadroomChangedObservations: volatileChanged,
      inputMaxHeadroomDifferences: volatileDifferences,
      examples: [...new Set(volatileExamples)].slice(0, 12),
    },
  };
}

function withoutGlassAmount(cell) {
  const result = { ...cell };
  delete result.glassAmount;
  return result;
}

function alignedStaticForTransparency(baseline, candidate, transparency) {
  const project = (archive, mode) => {
    const source = archive.static.observations;
    const observations = source
      .filter(({ cell }) => mode !== "axis"
        || cell.glassAmount === transparency.projectionAmount)
      .map((observation) => mode === "axis" ? {
        ...observation,
        cell: withoutGlassAmount(observation.cell),
      } : observation);
    return {
      document: { ...archive.static, observations },
      outsideProjection: source.length - observations.length,
    };
  };
  const left = project(baseline, transparency.baselineMode);
  const right = project(candidate, transparency.candidateMode);
  const leftByCell = new Map(left.document.observations.map((row) => [
    cellKey(row.cell, LEGACY_CELL_FIELDS), row,
  ]));
  const rightByCell = new Map(right.document.observations.map((row) => [
    cellKey(row.cell, LEGACY_CELL_FIELDS), row,
  ]));
  const shared = [...leftByCell.keys()].filter((key) => rightByCell.has(key));
  return {
    baseline: {
      ...left.document, observations: shared.map((key) => leftByCell.get(key)),
    },
    candidate: {
      ...right.document, observations: shared.map((key) => rightByCell.get(key)),
    },
    coverage: {
      baselineOnly: leftByCell.size - shared.length,
      candidateOnly: rightByCell.size - shared.length,
      baselineOutsideProjection: left.outsideProjection,
      candidateOutsideProjection: right.outsideProjection,
      compared: shared.length,
    },
  };
}

function legacyDynamicSample(sample) {
  if (!sample?.snapshot) return sample;
  const mapInputs = (inputs) => Object.fromEntries(
    (inputs ?? []).map(({ key, value }) => [key, value])
  );
  const model = sample.snapshot.model;
  return {
    ...(sample.progress === undefined ? {} : { progress: sample.progress }),
    requestedProgress: sample.requestedProgress,
    elapsed: sample.elapsed,
    phase: sample.phase,
    filters: (model.filters ?? []).map((filter) => ({
      ...filter,
      inputs: mapInputs(filter.inputs),
    })),
    effects: (model.effects ?? []).map((effect) => ({
      ...effect,
      inputs: mapInputs(effect.inputs),
    })),
    layerLines: model.layerLines ?? [],
  };
}

function alignedDynamicForTransparency(baseline, candidate, transparency) {
  const project = (archive, mode) => {
    const sourceRuns = archive.dynamic.runs;
    const runs = sourceRuns.filter(({ cell }) => mode !== "axis"
      || cell.glassAmount === transparency.projectionAmount).map((source) => {
      if (mode !== "axis") return source;
      const {
        requestedDuration: _requestedDuration,
        samplingDuration: _samplingDuration,
        context: _context,
        ...run
      } = source;
      return {
        ...run,
        cell: withoutGlassAmount(source.cell),
        samples: source.samples.map(legacyDynamicSample),
      };
    });
    return { runs, outsideProjection: sourceRuns.length - runs.length };
  };
  const left = project(baseline, transparency.baselineMode);
  const right = project(candidate, transparency.candidateMode);
  const leftByID = new Map(left.runs.map((run) => [
    JSON.stringify([run.animationMode, run.slice, cellKey(run.cell, LEGACY_CELL_FIELDS)]), run,
  ]));
  const rightByID = new Map(right.runs.map((run) => [
    JSON.stringify([run.animationMode, run.slice, cellKey(run.cell, LEGACY_CELL_FIELDS)]), run,
  ]));
  const shared = [...leftByID.keys()].filter((key) => rightByID.has(key));
  return {
    baseline: shared.map((key) => leftByID.get(key)),
    candidate: shared.map((key) => rightByID.get(key)),
    coverage: {
      baselineOnly: leftByID.size - shared.length,
      candidateOnly: rightByID.size - shared.length,
      baselineOutsideProjection: left.outsideProjection,
      candidateOutsideProjection: right.outsideProjection,
      compared: shared.length,
    },
  };
}

export function compareArchives(baseline, candidate) {
  const transparency = compareTransparency(baseline.capture, candidate.capture);
  const needsProjection = transparency.projectionAmount !== null
    && transparency.baselineMode !== transparency.candidateMode;
  const projected = needsProjection
    ? alignedStaticForTransparency(baseline, candidate, transparency) : null;
  const staticComparison = compareStaticDocuments(
    projected?.baseline ?? baseline.static,
    projected?.candidate ?? candidate.static,
    { compareCommonFields: needsProjection }
  );
  if (projected) staticComparison.coordinates = projected.coverage;

  const dynamicProjection = needsProjection
    ? alignedDynamicForTransparency(baseline, candidate, transparency) : null;
  const dynamicSampling = needsProjection ? comparableSampling(
    dynamicProjection.baseline,
    dynamicProjection.candidate
  ) : {
    baseline: baseline.dynamic.runs,
    candidate: candidate.dynamic.runs,
    coverage: { complete: true, missingComparisons: 0, examples: [] },
  };
  const dynamic = compareStableDynamicRuns(
    dynamicSampling.baseline, dynamicSampling.candidate
  );
  dynamic.coverage = {
    sampling: dynamicSampling.coverage,
    coordinates: dynamicProjection?.coverage ?? null,
  };
  dynamic.volatile = {
    inputMaxHeadroom: compareNamedValues(
      dynamicSampling.baseline, dynamicSampling.candidate,
      "inputMaxHeadroom", "dynamic"
    ),
  };
  const documents = [];
  for (const [, key] of [...TINT_DOCUMENTS, ["semantic.usage-trees", "semantic"]]) {
    const examples = [];
    const ignoredKeys = new Set([
      "capturedAt", "generatedAt", "operatingSystem", "timings",
      "transparency", "glassAmount",
    ]);
    if (key === "semantic") ignoredKeys.add("inputMaxHeadroom");
    const differences = countDifferences(baseline[key], candidate[key], key, examples, {
      tolerance: 1e-6, ignoredKeys,
    });
    const comparison = { file: ARCHIVE_FILES[key], differences, examples };
    if (key === "semantic") {
      comparison.volatile = {
        inputMaxHeadroom: compareNamedValues(
          baseline[key], candidate[key], "inputMaxHeadroom", key
        ),
      };
    }
    documents.push(comparison);
  }
  const measuredEquivalent = staticComparison.equivalent
    && dynamic.equivalent && documents.every(({ differences }) => differences === 0);
  const coordinateCoverageComplete = !needsProjection || (
    projected.coverage.baselineOnly === 0
      && projected.coverage.candidateOnly === 0
      && projected.coverage.baselineOutsideProjection === 0
      && projected.coverage.candidateOutsideProjection === 0
      && dynamicProjection.coverage.baselineOnly === 0
      && dynamicProjection.coverage.candidateOnly === 0
      && dynamicProjection.coverage.baselineOutsideProjection === 0
      && dynamicProjection.coverage.candidateOutsideProjection === 0
  );
  const coverageComplete = staticComparison.coverage.complete
    && dynamicSampling.coverage.complete && coordinateCoverageComplete;
  const environmentConfounded = !transparency.comparable
    || baseline.platform.displaySignature !== candidate.platform.displaySignature;
  return {
    schemaVersion: 1,
    equivalent: measuredEquivalent && coverageComplete && !environmentConfounded,
    measuredEquivalent,
    coverageComplete,
    baseline: baseline.directory,
    candidate: candidate.directory,
    baselinePlatform: baseline.platform,
    candidatePlatform: candidate.platform,
    transparency,
    environmentConfounded,
    static: staticComparison,
    dynamic,
    documents,
  };
}

export async function acceptedArchives(goldenDirectory) {
  const entries = await readdir(goldenDirectory, { withFileTypes: true });
  return entries.filter((entry) => entry.isDirectory() && /^macOS-[0-9]+$/.test(entry.name))
    .map((entry) => ({
      name: entry.name,
      major: Number(entry.name.slice("macOS-".length)),
      directory: path.join(goldenDirectory, entry.name),
    }))
    .sort((left, right) => left.major - right.major);
}

export async function finalizeStaging(partial, output) {
  await mkdir(path.dirname(output), { recursive: true });
  try {
    await rename(partial, output);
  } catch (error) {
    if (error?.code !== "EEXIST" && error?.code !== "ENOTEMPTY") throw error;
    const toolDirectory = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
    const result = spawnSync("xcrun", [
      "swift", path.join(toolDirectory, "atomic-promote.swift"), partial, output,
    ], { encoding: "utf8" });
    if (result.stderr) process.stderr.write(result.stderr);
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`atomic staging replacement exited ${result.status}`);
  }
}

export async function copyArchive(source, destination) {
  await rm(destination, { recursive: true, force: true });
  await cp(source, destination, { recursive: true });
  for (const file of COMPRESSED_ARCHIVE_FILES) {
    const plain = path.join(destination, file);
    const compressed = `${plain}.gz`;
    const temporary = `${compressed}.${process.pid}.tmp`;
    try {
      await access(plain);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    try {
      await rm(temporary, { force: true });
      await pipeline(
        createReadStream(plain),
        createGzip({ level: 9 }),
        createWriteStream(temporary, { flags: "wx" }),
      );
      await rename(temporary, compressed);
      await rm(plain);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
