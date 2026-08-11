import { createHash } from "node:crypto";
import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { validateManifestV2 } from "./manifest.mjs";
import { tintDocumentGateProblems } from "./tint-compare.mjs";

export const PROFILE_DEFINITION_VERSION = 1;

export const FULL_DRIVERS = [
  ["core", "--capture-golden", "unified"],
  ["tint.parameterization.sweep", "--capture-tint-parameterization", "tint-parameterization-sweep.json"],
  ["tint.parameterization.focused-2b", "--capture-tint-parameterization-focused", "tint-parameterization-focused-phase-2b.json"],
  ["tint.parameterization.hue-2c", "--capture-tint-parameterization-phase-2c", "tint-parameterization-hue-phase-2c.json"],
  ["tint.sync-resolution", "--verify-tint-sync-resolution", "tint-sync-resolution.json"],
  ["tint.wide-gamut", "--verify-tint-wide-gamut-model", "tint-wide-gamut-model.json"],
  ["semantic.usage-trees", "--capture-semantic-usage-trees", "semantic-usage-trees.json"],
];

export const FULL_MODULE_IDS = [
  "core.static-scalar", "core.static-tree", "core.dynamic",
  ...FULL_DRIVERS.slice(1).map(([id]) => id),
];

export const CLAIMS = {
  "core.static-scalar": ["recipe-values", "static-axis-response"],
  "core.static-tree": ["recursive-topology", "pass-inventory", "resolved-pass-values"],
  "core.dynamic": ["transition-curve", "dynamic-axis-response", "settled-endpoints"],
  "tint.parameterization.sweep": ["tint-transform-family", "tint-matrix-fit"],
  "tint.parameterization.focused-2b": ["tint-rgb-holdouts"],
  "tint.parameterization.hue-2c": ["tint-hue-boundary"],
  "tint.sync-resolution": ["flush-settled-tint-equivalence"],
  "tint.wide-gamut": ["display-p3-tint-model"],
  "semantic.usage-trees": ["semantic-role-topology"],
  "external.window-context": ["window-context-invariance"],
};

export const PAYLOAD_SCHEMA_VERSIONS = {
  "core.static-scalar": 1,
  "core.static-tree": 1,
  "core.dynamic": 1,
  "tint.parameterization.sweep": 1,
  "tint.parameterization.focused-2b": 1,
  "tint.parameterization.hue-2c": 1,
  "tint.sync-resolution": 1,
  "tint.wide-gamut": 1,
  "semantic.usage-trees": 2,
};

export const CORE_SHAPES = {
  "core.static-scalar": {
    collection: "rows", section: "static-scalar", total: 744,
    slices: { core: 672, cornerRadius: 12, key: 4, size: 48, transposed: 8 },
    identitySha256: "bf1bdeb0a90d1bd16c8f562ee3c53a6a91dda63bc2688f948919e376ea222192",
  },
  "core.static-tree": {
    collection: "rows", section: "static-tree", total: 378,
    slices: { appearance: 21, core: 336, repeat: 21 },
    identitySha256: "807e7d42c7dfb93bf3a1723a2f7cb81d1c63c92fe4a395d3625259ea539b7177",
  },
  "core.dynamic": {
    collection: "runs", section: "dynamic", total: 104,
    slices: { backdrop: 4, core: 96, repeat: 4 }, samplesPerRun: 9,
    identitySha256: "09d411327787f01df758ec42943128fe7bc07b163e4bc277f689c2cc6c42c748",
  },
};

const TINT_SHAPES = {
  "tint.parameterization.sweep": {
    rows: 1360,
    identitySha256: "ab7196efef390b9ec3af3e77e00610b9540662f362496db63c1bb703ab62b2ea",
    planColors: 170,
    planSha256: "3278cafefe287cbd2ee3a94240ffec60fe037cf715683f192ff480e02361ffa4",
  },
  "tint.parameterization.focused-2b": {
    rows: 1048,
    identitySha256: "ccb99e5883485885c65c84dc358ce060565d3b19e3969b28264eaf15585819dc",
    planColors: 131,
    planSha256: "ac6e97d031972ab90148699f3928533e87cb6738800f02889eb010da5be31869",
  },
  "tint.parameterization.hue-2c": {
    rows: 1088,
    identitySha256: "5945d260822d1b9519fdc76b73cd3024cf6b1d3610262d8da0f9efd0d7db4b1a",
    planColors: 136,
    planSha256: "329194f932162d4da46965d10bf1765a56b1ce65f96a5c48dc6c4f5062c7c1da",
  },
  "tint.sync-resolution": {
    rows: 128,
    identitySha256: "ee8eb7e5fc096e869937bbae570b07c23571ae6a9a96d246107841a2cf2c7680",
  },
  "tint.wide-gamut": {
    rows: 408,
    identitySha256: "69075507d18dd9b254b8bfe7415b90ba759d75b862e6cf98be092d540e1f2659",
  },
};

const CORE_CELL_FIELDS = [
  "variant", "subvariant", "main", "key", "subdued", "appearance",
  "backdrop", "tint", "width", "height", "cornerRadius", "host", "direction",
];

export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function platformFrom(operatingSystem, architecture = process.arch) {
  const version = /Version ([0-9.]+)/.exec(operatingSystem)?.[1]
    ?? /macOS ([0-9.]+)/.exec(operatingSystem)?.[1] ?? "unknown";
  const build = /Build ([^)]+)/.exec(operatingSystem)?.[1] ?? "unknown";
  return { product: "macOS", version, build, architecture };
}

export function profileForMajor(osMajor) {
  const required = osMajor >= 27
    ? [...FULL_MODULE_IDS]
    : FULL_MODULE_IDS.filter((id) => id !== "semantic.usage-trees");
  return {
    required,
    optional: osMajor >= 27 ? [] : ["semantic.usage-trees"],
    unsupported: [],
  };
}

export function safeModulePath(file) {
  if (typeof file !== "string" || file.length === 0 || path.isAbsolute(file)) return false;
  if (file.includes("\0") || file.includes("\\")
      || file.split("/").some((part) => !part || part === "." || part === "..")) {
    return false;
  }
  return path.posix.normalize(file) === file;
}

function cellIdentity(row) {
  return JSON.stringify([
    row.slice ?? null,
    ...CORE_CELL_FIELDS.map((field) => row.cell?.[field] ?? null),
  ]);
}

function coreAdmissionProblems(id, payload) {
  const shape = CORE_SHAPES[id];
  if (!shape) return [];
  const problems = [];
  if (payload.section !== shape.section) problems.push(`${id}: section must be ${shape.section}`);
  const items = payload[shape.collection];
  if (!Array.isArray(items)) return [...problems, `${id}: ${shape.collection} must be an array`];
  if (items.length !== shape.total) problems.push(`${id}: expected ${shape.total} ${shape.collection}, got ${items.length}`);
  const slices = {};
  const identities = new Set();
  for (const [index, item] of items.entries()) {
    slices[item.slice] = (slices[item.slice] ?? 0) + 1;
    const identity = cellIdentity(item);
    if (identities.has(identity)) problems.push(`${id}: duplicate identity at ${index}`);
    identities.add(identity);
    if (item.accepted !== true) problems.push(`${id}: row ${index} was not accepted by the capture driver`);
    if (!item.cell || [...CORE_CELL_FIELDS, "shortSide"].some((field) =>
      !Object.hasOwn(item.cell ?? {}, field))
        || Object.values(item.cell).some((value) => typeof value === "number" && !Number.isFinite(value))) {
      problems.push(`${id}: invalid cell at ${index}`);
    } else if (!Number.isFinite(item.cell.width) || !Number.isFinite(item.cell.height)
        || item.cell.shortSide !== Math.min(item.cell.width, item.cell.height)) {
      problems.push(`${id}: cell ${index} has an inconsistent shortSide`);
    }
    if (id === "core.dynamic") {
      if (!Number.isFinite(item.maximumAttachedAnimationDuration)) {
        problems.push(`${id}: run ${index} has no finite maximumAttachedAnimationDuration`);
      }
      if (!Array.isArray(item.samples) || item.samples.length !== shape.samplesPerRun) {
        problems.push(`${id}: run ${index} must contain ${shape.samplesPerRun} samples`);
      } else if (item.samples.some((sample) => !Number.isFinite(sample.requestedProgress)
          || !Number.isFinite(sample.elapsed)
          || (sample.progress != null && !Number.isFinite(sample.progress))
          || !Array.isArray(sample.effects) || !Array.isArray(sample.filters)
          || !Array.isArray(sample.layerLines) || sample.layerLines.length === 0)) {
        problems.push(`${id}: run ${index} has non-finite timing or progress`);
      }
    }
    if (id === "core.static-scalar"
        && ["inputs", "passes", "geometry", "colors", "points", "strings", "highlight"]
          .some((field) => !item[field] || typeof item[field] !== "object")) {
      problems.push(`${id}: row ${index} is missing captured scalar payload fields`);
    }
    if (id === "core.static-tree"
        && (!item.layers || typeof item.layers !== "object"
          || !item.passes || typeof item.passes !== "object"
          || typeof item.topologySignature !== "string" || item.topologySignature.length !== 64
          || typeof item.valueSignature !== "string" || item.valueSignature.length !== 64)) {
      problems.push(`${id}: row ${index} is missing captured tree payload fields`);
    }
  }
  if (Object.keys(slices).length !== Object.keys(shape.slices).length
      || Object.entries(shape.slices).some(([slice, count]) => slices[slice] !== count)) {
    problems.push(`${id}: slice counts ${JSON.stringify(slices)} != ${JSON.stringify(shape.slices)}`);
  }
  const identitySha256 = sha256(Buffer.from(JSON.stringify([...identities].sort())));
  if (identitySha256 !== shape.identitySha256) {
    problems.push(`${id}: captured axes do not match the registered Full coordinate set`);
  }
  return problems;
}

function matrixIsFinite(matrix) {
  return Array.isArray(matrix) && matrix.length === 20 && matrix.every(Number.isFinite);
}

function tintAdmissionProblems(id, payload) {
  const shape = TINT_SHAPES[id];
  const problems = tintDocumentGateProblems(payload, id);
  if (!shape) return problems;
  if (!Array.isArray(payload.rows) || payload.rows.length !== shape.rows) {
    return [...problems, `${id}: expected ${shape.rows} rows, got ${payload.rows?.length ?? "none"}`];
  }
  const identities = new Set();
  for (const [index, row] of payload.rows.entries()) {
    const cell = row.cell ?? {};
    const identity = JSON.stringify([
      row.colorID, cell.isLightAppearance, cell.isClear, cell.hasMainParticipation,
    ]);
    if (identities.has(identity)) problems.push(`${id}: duplicate row identity at ${index}`);
    identities.add(identity);
    if (typeof row.colorID !== "string"
        || ![cell.isLightAppearance, cell.isClear, cell.hasMainParticipation]
          .every((value) => typeof value === "boolean")) {
      problems.push(`${id}: invalid row identity at ${index}`);
    }
    if (id.startsWith("tint.parameterization.")) {
      if (!matrixIsFinite(row.matrix)) problems.push(`${id}: row ${index} has no finite 4x5 matrix`);
    } else if (!matrixIsFinite(row.flushMatrix) || !matrixIsFinite(row.settledMatrix)
        || row.passed !== true || row.pairedProofAtFlush !== true
        || row.pairedProofWhenSettled !== true || !Number.isFinite(row.maximumDifference)) {
      problems.push(`${id}: row ${index} failed paired matrix proof admission`);
    }
  }
  const identitySha256 = sha256(Buffer.from(JSON.stringify([...identities].sort())));
  if (identitySha256 !== shape.identitySha256) {
    problems.push(`${id}: captured rows do not match the registered Tint coordinate set`);
  }
  if (shape.planColors !== undefined) {
    const colors = payload.plan?.colors;
    const planSha256 = Array.isArray(colors)
      ? sha256(Buffer.from(JSON.stringify(colors.map((color) => JSON.stringify(color)).sort()))) : null;
    if (colors?.length !== shape.planColors || planSha256 !== shape.planSha256) {
      problems.push(`${id}: capture plan does not match the registered Tint color set`);
    }
  }
  return problems;
}

function semanticSnapshotIsComplete(snapshot) {
  return snapshot && Array.isArray(snapshot.layerLines) && snapshot.layerLines.length > 0
    && Array.isArray(snapshot.filters) && Array.isArray(snapshot.effects)
    && snapshot.filters.length + snapshot.effects.length > 0;
}

export function semanticAdmissionProblems(payload, { osMajor: authoritativeOSMajor = null } = {}) {
  const context = payload.context ?? {};
  const canonicalContext = context.hostType === "Panel"
    && context.glassWidth === 480 && context.glassHeight === 200
    && context.cornerRadius === 16 && context.windowMargin === 40;
  const entries = payload.entries;
  const payloadOSMajor = Number.parseInt(platformFrom(payload.operatingSystem ?? "").version, 10);
  const osMajor = authoritativeOSMajor ?? payloadOSMajor;
  const identities = new Set((Array.isArray(entries) ? entries : []).map((entry) =>
    JSON.stringify([entry.roleTag, entry.requestedMain])));
  const expectedIdentities = new Set(Array.from({ length: 24 }, (_, roleTag) =>
    [false, true].map((requestedMain) => JSON.stringify([roleTag, requestedMain]))).flat());
  const invalidEntry = !Array.isArray(entries) || entries.length !== 48
    || identities.size !== 48 || [...expectedIdentities].some((identity) => !identities.has(identity))
    || !Number.isInteger(osMajor)
    || entries.some((entry) => entry.actualKey !== false
      || entry.actualMain !== entry.requestedMain
      || (entry.isAvailable === true && !semanticSnapshotIsComplete(entry.snapshot))
      || (entry.isAvailable === false && (osMajor >= 27 || entry.snapshot != null))
      || typeof entry.isAvailable !== "boolean");
  return canonicalContext && !invalidEntry
    ? [] : ["semantic.usage-trees failed canonical context or completeness gates"];
}

export function moduleAdmissionProblems(id, payload, options = {}) {
  const problems = [];
  const payloadSchemaVersion = payload.formatVersion ?? payload.schemaVersion ?? 1;
  if (options.expectedSchemaVersion !== undefined
      && payloadSchemaVersion !== options.expectedSchemaVersion) {
    problems.push(`${id}: payload schema must be ${options.expectedSchemaVersion}`);
  }
  if (options.expectedPlatform) {
    const embedded = platformFrom(payload.operatingSystem ?? "", options.expectedPlatform.architecture);
    if (embedded.product !== options.expectedPlatform.product
        || embedded.version !== options.expectedPlatform.version
        || embedded.build !== options.expectedPlatform.build) {
      problems.push(`${id}: embedded operating system disagrees with module platform`);
    }
  }
  if (id.startsWith("core.")) problems.push(...coreAdmissionProblems(id, payload));
  else if (id.startsWith("tint.")) problems.push(...tintAdmissionProblems(id, payload));
  else if (id === "semantic.usage-trees") {
    problems.push(...semanticAdmissionProblems(payload, { osMajor: options.osMajor }));
  }
  return problems;
}

export async function payloadModule(root, id, file) {
  const bytes = await readFile(path.join(root, file));
  const payload = JSON.parse(bytes);
  const platform = platformFrom(payload.operatingSystem ?? "");
  const problems = moduleAdmissionProblems(id, payload, {
    osMajor: Number.parseInt(platform.version, 10),
    expectedPlatform: platform,
    expectedSchemaVersion: PAYLOAD_SCHEMA_VERSIONS[id],
  });
  if (problems.length) throw new Error(`${id} failed admission: ${problems.join("; ")}`);
  const capturedAt = payload.capturedAt ?? payload.generatedAt ?? null;
  return {
    id, file, payloadSchemaVersion: payload.formatVersion ?? payload.schemaVersion ?? 1,
    planVersion: PROFILE_DEFINITION_VERSION,
    platform, capturedAt,
    capture: { environment: payload.environment ?? payload.context ?? null, sessionID: payload.sessionID ?? null },
    provenance: { kind: "direct-capture" }, coverageClaims: CLAIMS[id],
    integrity: { sha256: sha256(bytes), bytes: bytes.length }, role: "canonical",
    profileStatus: "required",
  };
}

async function scanDirectory(root, relative, registered, problems) {
  for (const entry of await readdir(path.join(root, relative), { withFileTypes: true })) {
    const file = path.posix.join(relative, entry.name);
    const absolute = path.join(root, file);
    const info = await lstat(absolute);
    if (info.isSymbolicLink()) {
      problems.push(`${file}: symlinks are forbidden`);
    } else if (info.isDirectory()) {
      await scanDirectory(root, file, registered, problems);
    } else if (!info.isFile()) {
      problems.push(`${file}: special files are forbidden`);
    } else if (file !== "manifest.json" && !registered.has(file)) {
      problems.push(`${file}: on disk but unregistered`);
    }
  }
}

export async function validateFullDirectory(root, { expectedStatus = null } = {}) {
  const problems = [];
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(root, "manifest.json"), "utf8"));
  } catch (error) {
    return { manifest: null, documents: new Map(), problems: [`manifest.json: ${error.message}`] };
  }
  problems.push(...validateManifestV2(manifest));
  if (expectedStatus && manifest.status !== expectedStatus) {
    problems.push(`manifest.status must be ${expectedStatus}`);
  }
  const osMajor = Number.parseInt(manifest.platform?.version, 10);
  if (manifest.platform?.product !== "macOS" || !manifest.platform?.build
      || !manifest.platform?.architecture) {
    problems.push("manifest platform must declare macOS product, build, and architecture");
  }
  if (!/^[0-9]+(?:\.[0-9]+)*$/.test(manifest.platform?.version ?? "")) {
    problems.push("manifest platform version must be numeric dotted form");
  }
  const expected = profileForMajor(osMajor);
  const declaredBuilds = new Set(manifest.profiles?.full?.builds ?? []);
  for (const field of ["required", "optional", "unsupported"]) {
    if (JSON.stringify(manifest.profiles?.full?.[field] ?? []) !== JSON.stringify(expected[field])) {
      problems.push(`full.${field} does not match profile definition v${PROFILE_DEFINITION_VERSION}`);
    }
  }
  const directIDs = new Set([...expected.required, ...expected.optional]);
  const registeredPathKeys = new Set();
  for (const module of manifest.modules ?? []) {
    if (!safeModulePath(module.file)) problems.push(`${module.id}: unsafe module path ${module.file}`);
    const pathKey = typeof module.file === "string" ? module.file.normalize("NFC").toLowerCase() : "";
    if (registeredPathKeys.has(pathKey)) problems.push(`${module.id}: duplicate or case-colliding module path`);
    registeredPathKeys.add(pathKey);
    if (directIDs.has(module.id)) {
      const expectedState = expected.required.includes(module.id) ? "required" : "optional";
      if (module.profileStatus !== expectedState) problems.push(`${module.id}: expected ${expectedState} status`);
      if (module.planVersion !== PROFILE_DEFINITION_VERSION) {
        problems.push(`${module.id}: planVersion must be ${PROFILE_DEFINITION_VERSION}`);
      }
      if (JSON.stringify(module.coverageClaims) !== JSON.stringify(CLAIMS[module.id])) {
        problems.push(`${module.id}: coverage claims do not match the registered Full contract`);
      }
      if (module.role !== "canonical" || module.provenance?.kind !== "direct-capture") {
        problems.push(`${module.id}: Full modules must be canonical direct captures`);
      }
      if (module.platform?.product !== manifest.platform?.product
          || module.platform?.version !== manifest.platform?.version
          || module.platform?.architecture !== manifest.platform?.architecture
          || !declaredBuilds.has(module.platform?.build)) {
        problems.push(`${module.id}: platform product, version, build, or architecture disagrees with Full metadata`);
      }
      if (module.payloadSchemaVersion !== PAYLOAD_SCHEMA_VERSIONS[module.id]) {
        problems.push(`${module.id}: payload schema version does not match the registered Full profile`);
      }
    }
  }
  for (const id of expected.required) {
    if (!(manifest.modules ?? []).some((module) => module.id === id)) problems.push(`${id}: required module missing`);
  }
  const registered = new Set(["unified/meta.json"]);
  const documents = new Map();
  for (const module of manifest.modules ?? []) {
    if (!safeModulePath(module.file)) continue;
    registered.add(module.file);
    try {
      const absolute = path.join(root, module.file);
      const info = await lstat(absolute);
      if (!info.isFile() || info.isSymbolicLink()) throw new Error("not a regular file");
      const bytes = await readFile(absolute);
      if (bytes.length !== module.integrity?.bytes) problems.push(`${module.file}: byte count disagrees with manifest`);
      if (sha256(bytes) !== module.integrity?.sha256) problems.push(`${module.file}: sha256 mismatch`);
      const payload = JSON.parse(bytes.toString("utf8"));
      documents.set(module.id, payload);
      const payloadSchemaVersion = payload.formatVersion ?? payload.schemaVersion ?? 1;
      if (module.payloadSchemaVersion !== payloadSchemaVersion) {
        problems.push(`${module.file}: payload schema version disagrees with manifest`);
      }
      problems.push(...moduleAdmissionProblems(module.id, payload, directIDs.has(module.id) ? {
        osMajor,
        expectedPlatform: module.platform,
        expectedSchemaVersion: PAYLOAD_SCHEMA_VERSIONS[module.id],
      } : {}));
    } catch (error) {
      problems.push(`${module.file}: ${error instanceof SyntaxError ? "not valid JSON" : error.message}`);
    }
  }
  try {
    const meta = JSON.parse(await readFile(path.join(root, "unified/meta.json"), "utf8"));
    for (const module of (manifest.modules ?? []).filter(({ id }) => id.startsWith("core."))) {
      const entry = meta.sections?.[module.id.slice("core.".length)];
      if (!entry || entry.file !== path.basename(module.file)
          || entry.sha256 !== module.integrity.sha256 || entry.bytes !== module.integrity.bytes) {
        problems.push(`${module.file}: unified metadata disagrees with manifest`);
      }
    }
  } catch {
    problems.push("unified/meta.json: missing or not valid JSON");
  }
  try {
    await scanDirectory(root, "", registered, problems);
  } catch (error) {
    problems.push(`directory scan failed: ${error.message}`);
  }
  try {
    if ((await lstat(root)).isSymbolicLink()) problems.push("directory root must not be a symlink");
  } catch (error) {
    problems.push(`directory root cannot be inspected: ${error.message}`);
  }
  return { manifest, documents, problems };
}
