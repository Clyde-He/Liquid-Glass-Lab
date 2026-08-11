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
    if (!item.cell || Object.values(item.cell).some((value) => typeof value === "number" && !Number.isFinite(value))) {
      problems.push(`${id}: invalid cell at ${index}`);
    }
    if (id === "core.dynamic") {
      if (!Number.isFinite(item.maximumAttachedAnimationDuration)) {
        problems.push(`${id}: run ${index} has no finite maximumAttachedAnimationDuration`);
      }
      if (!Array.isArray(item.samples) || item.samples.length !== shape.samplesPerRun) {
        problems.push(`${id}: run ${index} must contain ${shape.samplesPerRun} samples`);
      } else if (item.samples.some((sample) => !Number.isFinite(sample.requestedProgress)
          || !Number.isFinite(sample.elapsed)
          || (sample.progress != null && !Number.isFinite(sample.progress)))) {
        problems.push(`${id}: run ${index} has non-finite timing or progress`);
      }
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

export function semanticAdmissionProblems(payload) {
  const context = payload.context ?? {};
  const canonicalContext = context.hostType === "Panel"
    && context.glassWidth === 480 && context.glassHeight === 200
    && context.cornerRadius === 16 && context.windowMargin === 40;
  const entries = payload.entries;
  const identities = new Set((Array.isArray(entries) ? entries : []).map((entry) =>
    JSON.stringify([entry.roleTag, entry.requestedMain])));
  const invalidEntry = !Array.isArray(entries) || entries.length !== 48
    || identities.size !== 48
    || entries.some((entry) => entry.actualKey !== false
      || entry.actualMain !== entry.requestedMain
      || entry.isAvailable !== true || entry.snapshot == null);
  return canonicalContext && !invalidEntry
    ? [] : ["semantic.usage-trees failed canonical context or completeness gates"];
}

export function moduleAdmissionProblems(id, payload) {
  if (id.startsWith("core.")) return coreAdmissionProblems(id, payload);
  if (id.startsWith("tint.")) return tintDocumentGateProblems(payload, id);
  if (id === "semantic.usage-trees") return semanticAdmissionProblems(payload);
  return [];
}

export async function payloadModule(root, id, file) {
  const bytes = await readFile(path.join(root, file));
  const payload = JSON.parse(bytes);
  const problems = moduleAdmissionProblems(id, payload);
  if (problems.length) throw new Error(`${id} failed admission: ${problems.join("; ")}`);
  const capturedAt = payload.capturedAt ?? payload.generatedAt ?? null;
  return {
    id, file, payloadSchemaVersion: payload.formatVersion ?? payload.schemaVersion ?? 1,
    planVersion: PROFILE_DEFINITION_VERSION,
    platform: platformFrom(payload.operatingSystem ?? ""), capturedAt,
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
  if (!/^[0-9]+(?:\.[0-9]+)*$/.test(manifest.platform?.version ?? "")) {
    problems.push("manifest platform version must be numeric dotted form");
  }
  const expected = profileForMajor(osMajor);
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
      problems.push(...moduleAdmissionProblems(module.id, payload));
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
