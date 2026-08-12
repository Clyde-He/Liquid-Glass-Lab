import { cp, mkdir, readFile, readdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import { cellKey, CELL_FIELDS } from "./cell.mjs";
import {
  dynamicLifecycleProblems, dynamicPairingProblems,
} from "./dynamic-contract.mjs";
import { compareStableDynamicRuns } from "./dynamic-equivalence.mjs";
import { projectStaticTree, projectStyleSample } from "./snapshot-projections.mjs";
import { tintDocumentGateProblems } from "./tint-compare.mjs";

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

export async function readArchive(directory) {
  const capture = await readJSON(path.join(directory, ARCHIVE_FILES.capture));
  const platform = platformFromCapture(capture);
  const documents = { capture };
  const required = Object.entries(ARCHIVE_FILES).filter(
    ([name]) => !["capture", "semantic"].includes(name)
  );
  await Promise.all(required.map(async ([name, file]) => {
    documents[name] = await readJSON(path.join(directory, file));
  }));
  if (platform.major >= 27) {
    documents.semantic = await readJSON(path.join(directory, ARCHIVE_FILES.semantic));
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

function cellProblems(cell, label) {
  const problems = [];
  const missing = [...CELL_FIELDS, "shortSide"].filter((field) => !Object.hasOwn(cell ?? {}, field));
  if (missing.length) problems.push(`${label}: cell is missing ${missing.join(", ")}`);
  if (!finite(cell)) problems.push(`${label}: cell contains a non-finite value`);
  if (Number.isFinite(cell?.width) && Number.isFinite(cell?.height)
      && cell.shortSide !== Math.min(cell.width, cell.height)) {
    problems.push(`${label}: shortSide disagrees with width and height`);
  }
  return problems;
}

function validateStatic(archive) {
  const problems = [];
  const document = archive.static;
  if (document?.schemaVersion !== 2 || !Array.isArray(document.observations)) {
    return ["static.json must be a schema-2 observation document"];
  }
  if (document.observations.length !== 776) {
    problems.push(`static.json must contain 776 observations; got ${document.observations.length}`);
  }
  const observations = new Map();
  for (const [index, observation] of document.observations.entries()) {
    problems.push(...cellProblems(observation.cell, `static observation ${index}`));
    const key = cellKey(observation.cell);
    if (observations.has(key)) problems.push(`static observation ${index} duplicates ${key}`);
    observations.set(key, observation);
    const snapshot = observation.snapshot;
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

  if (!Array.isArray(document.consumerCells) || document.consumerCells.length !== 56) {
    problems.push(`static.json must declare 56 Consumer cells; got ${document.consumerCells?.length ?? 0}`);
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

function validateDynamic(archive) {
  const problems = [];
  const runs = archive.dynamic?.runs;
  if (archive.dynamic?.schemaVersion !== 2 || !Array.isArray(runs)) {
    return ["dynamic.json must be a schema-2 run document"];
  }
  if (runs.length !== 104) problems.push(`dynamic.json must contain 104 runs; got ${runs.length}`);
  for (const [index, run] of runs.entries()) {
    problems.push(...cellProblems(run.cell, `Dynamic run ${index}`));
    if (run.accepted !== true || !Number.isFinite(run.maximumAttachedAnimationDuration)) {
      problems.push(`Dynamic run ${index} was not accepted or has no finite duration`);
    }
    problems.push(...dynamicLifecycleProblems(run, index));
    if (!finite(run.samples)) problems.push(`Dynamic run ${index} contains non-finite samples`);
  }
  problems.push(...dynamicPairingProblems(runs));
  return problems;
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
        || row.passed !== true || row.pairedProofAtFlush !== true
        || row.pairedProofWhenSettled !== true) {
      problems.push(`${id}: row ${index} failed paired finite-matrix proof`);
    }
  }
  if (id.startsWith("tint.parameterization.")) {
    const planned = document.plan?.colors?.length;
    if (Number.isInteger(planned) && document.rows.length !== planned * 8) {
      problems.push(`${id}: ${document.rows.length} rows do not cover ${planned} colors × 8 cells`);
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
  return problems;
}

function embeddedOSProblems(archive) {
  const problems = [];
  for (const [name, document] of [
    ...TINT_DOCUMENTS.map(([id, key]) => [id, archive[key]]),
    ["semantic.usage-trees", archive.semantic],
  ]) {
    if (!document) continue;
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
  if (archive.capture?.schemaVersion !== 2 || archive.platform.major === null
      || !archive.platform.build || !archive.platform.architecture
      || !archive.platform.displaySignature || !archive.capture.capturedAt) {
    problems.push("capture.json lacks schema-2 OS/build/architecture/display provenance");
  }
  problems.push(...validateStatic(archive));
  problems.push(...validateDynamic(archive));
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
    return Math.abs(left - right) <= (options.tolerance ?? 0) ? 0 : 1;
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
      count += countDifferences(left[key], right[key], pathName ? `${pathName}.${key}` : key,
        examples, options);
    }
    return count;
  }
  if (examples.length < 12) examples.push(pathName || "root");
  return 1;
}

export function compareArchives(baseline, candidate) {
  const staticBaseline = new Map(
    baseline.static.observations.map((observation) => [cellKey(observation.cell), observation])
  );
  const staticCandidate = new Map(
    candidate.static.observations.map((observation) => [cellKey(observation.cell), observation])
  );
  const staticExamples = [];
  let staticChanged = 0;
  let staticDifferences = 0;
  for (const key of new Set([...staticBaseline.keys(), ...staticCandidate.keys()])) {
    const count = countDifferences(
      staticBaseline.get(key)?.snapshot,
      staticCandidate.get(key)?.snapshot,
      key,
      staticExamples,
      { tolerance: 1e-6, ignoredKeys: new Set(["inputMaxHeadroom"]) }
    );
    if (count) staticChanged += 1;
    staticDifferences += count;
  }
  const baselineTree = projectStaticTree(baseline.static);
  const candidateTree = projectStaticTree(candidate.static);
  const baselineTopology = new Map(
    baselineTree.rows.map((row) => [cellKey(row.cell), row.topologySignature])
  );
  const candidateTopology = new Map(
    candidateTree.rows.map((row) => [cellKey(row.cell), row.topologySignature])
  );
  const topologyChanged = [...new Set([
    ...baselineTopology.keys(), ...candidateTopology.keys(),
  ])].filter((key) => baselineTopology.get(key) !== candidateTopology.get(key)).length;

  const dynamic = compareStableDynamicRuns(baseline.dynamic.runs, candidate.dynamic.runs);
  const documents = [];
  for (const [, key] of [...TINT_DOCUMENTS, ["semantic.usage-trees", "semantic"]]) {
    const examples = [];
    const differences = countDifferences(baseline[key], candidate[key], key, examples, {
      tolerance: 1e-6,
      ignoredKeys: new Set(["capturedAt", "generatedAt", "operatingSystem", "timings"]),
    });
    documents.push({ file: ARCHIVE_FILES[key], differences, examples });
  }
  const equivalent = staticDifferences === 0 && topologyChanged === 0
    && dynamic.equivalent && documents.every(({ differences }) => differences === 0);
  return {
    schemaVersion: 1,
    equivalent,
    baseline: baseline.directory,
    candidate: candidate.directory,
    static: {
      changedObservations: staticChanged,
      changedFields: staticDifferences,
      topologyChangedObservations: topologyChanged,
      examples: [...new Set(staticExamples)].slice(0, 12),
    },
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
    const previous = `${output}.previous-${process.pid}`;
    await rename(output, previous);
    try {
      await rename(partial, output);
      await rm(previous, { recursive: true, force: true });
    } catch (replacementError) {
      await rename(previous, output);
      throw replacementError;
    }
  }
}

export async function copyArchive(source, destination) {
  await rm(destination, { recursive: true, force: true });
  await cp(source, destination, { recursive: true });
}
