import { readFile } from "node:fs/promises";
import path from "node:path";

export const MANIFEST_PROTOCOL_VERSION = 2;
export const PROFILE_STATES = [
  "required", "optional", "unsupported", "carried-forward", "excluded",
];

const LEGACY_MODULE_IDS = {
  "recipe-matrix": "legacy.recipe-matrix",
  "recursive-pass-audit": "legacy.recursive-pass-audit",
  "materialize-environment-matrix": "legacy.materialize-environment",
  "materialize-geometry-sweep": "legacy.materialize-geometry",
  "semantic-usage-trees": "semantic.usage-trees",
  "tint-parameterization-sweep": "tint.parameterization.sweep",
  "tint-parameterization-focused-phase-2b": "tint.parameterization.focused-2b",
  "tint-parameterization-hue-phase-2c": "tint.parameterization.hue-2c",
  "tint-sync-resolution": "tint.sync-resolution",
  "tint-wide-gamut-model": "tint.wide-gamut",
  "formula-analysis": "research.formula-analysis",
  "window-context-matrix": "external.window-context",
  "recursive-pass-audit-stability-repeat": "control.recursive-stability",
  "recursive-pass-audit-display-context-a": "control.recursive-display-context",
};

export const KNOWN_MODULE_IDS = new Set([
  ...Object.values(LEGACY_MODULE_IDS),
  "core.static-scalar", "core.static-tree", "core.dynamic",
]);

export const legacyModuleID = (fixtureID) =>
  LEGACY_MODULE_IDS[fixtureID] ?? `legacy.${fixtureID}`;

export function validateManifestV2(manifest) {
  const problems = [];
  if (manifest.protocolVersion !== MANIFEST_PROTOCOL_VERSION) {
    problems.push(`protocolVersion must be ${MANIFEST_PROTOCOL_VERSION}`);
  }
  const modules = manifest.modules ?? [];
  if (!Array.isArray(manifest.modules)) problems.push("modules must be an array");
  if (!manifest.profiles?.full) problems.push("profiles.full is required");
  const ids = new Set();
  const files = new Set();
  for (const module of modules) {
    if (!module.id) problems.push("module has no id");
    else if (ids.has(module.id)) problems.push(`duplicate module id ${module.id}`);
    else ids.add(module.id);
    if (!module.file) problems.push(`${module.id ?? "module"} has no file`);
    else if (files.has(module.file)) problems.push(`duplicate module file ${module.file}`);
    else files.add(module.file);
    if (!PROFILE_STATES.includes(module.profileStatus)) {
      problems.push(`${module.id}: invalid profileStatus ${module.profileStatus}`);
    }
    if (!module.integrity?.sha256) problems.push(`${module.id}: no integrity.sha256`);
    if (!Number.isInteger(module.integrity?.bytes) || module.integrity.bytes < 0) {
      problems.push(`${module.id}: integrity.bytes must be a non-negative integer`);
    }
    if (!Number.isInteger(module.payloadSchemaVersion) || !Number.isInteger(module.planVersion)) {
      problems.push(`${module.id}: schema and plan versions must be integers`);
    }
    for (const field of ["product", "version", "build", "architecture"]) {
      if (!module.platform?.[field]) problems.push(`${module.id}: no platform.${field}`);
    }
    if (!("capturedAt" in module)) problems.push(`${module.id}: capturedAt is not explicit`);
    if (!module.capture || !("environment" in module.capture) || !("sessionID" in module.capture)) {
      problems.push(`${module.id}: capture environment/session provenance is incomplete`);
    }
    if (!module.provenance?.kind) problems.push(`${module.id}: no provenance.kind`);
    if (!['canonical', 'control', 'derived'].includes(module.role)) {
      problems.push(`${module.id}: invalid role ${module.role}`);
    }
    if (!Array.isArray(module.coverageClaims) || module.coverageClaims.length === 0) {
      problems.push(`${module.id}: coverageClaims must be a non-empty array`);
    }
  }
  for (const [profileName, profile] of Object.entries(manifest.profiles ?? {})) {
    for (const field of ["required", "optional", "unsupported", "carriedForward"]) {
      if (!Array.isArray(profile[field])) problems.push(`${profileName}.${field} must be an array`);
      for (const id of profile[field] ?? []) {
        if (!ids.has(id) && !(["optional", "unsupported"].includes(field) && KNOWN_MODULE_IDS.has(id))) {
          problems.push(`${profileName}.${field}: unknown module ${id}`);
        }
      }
    }
    const listed = [
      ...(profile.required ?? []), ...(profile.optional ?? []),
      ...(profile.unsupported ?? []), ...(profile.carriedForward ?? []),
    ];
    if (new Set(listed).size !== listed.length) {
      problems.push(`${profileName}: module listed in more than one state`);
    }
    if (profileName === "full") for (const module of modules) {
      const expectedField = {
        required: "required", optional: "optional",
        "carried-forward": "carriedForward",
        unsupported: "unsupported",
      }[module.profileStatus];
      if (expectedField && !(profile[expectedField] ?? []).includes(module.id)) {
        problems.push(`${profileName}: ${module.id} is ${module.profileStatus} but not listed`);
      }
      if (module.profileStatus === "excluded" && listed.includes(module.id)) {
        problems.push(`${profileName}: excluded module ${module.id} is listed`);
      }
    }
  }
  return problems;
}

export async function normalizeManifest(raw, { osDirectory, goldenDirectory }) {
  if (raw.protocolVersion === MANIFEST_PROTOCOL_VERSION) {
    const problems = validateManifestV2(raw);
    if (problems.length > 0) throw new Error(`invalid manifest v2: ${problems.join("; ")}`);
    return {
      ...raw,
      sourceProtocolVersion: MANIFEST_PROTOCOL_VERSION,
      fixtures: raw.modules
        .filter((module) => !module.file.startsWith("unified/"))
        .map((module) => moduleAsLegacyFixture(module, raw.fixtures ?? [])),
    };
  }

  const modules = (raw.fixtures ?? []).map((fixture) => ({
    id: legacyModuleID(fixture.id),
    file: fixture.file,
    payloadSchemaVersion: fixture.schemaVersion ?? fixture.formatVersion ?? 1,
    planVersion: 1,
    platform: fixture.platform ?? raw.platform ?? null,
    capturedAt: fixture.capturedAt ?? raw.capturedAt ?? null,
    capture: { environment: fixture.environment ?? null, sessionID: null },
    provenance: { kind: "legacy-fixture", fixtureID: fixture.id },
    coverageClaims: [],
    integrity: { sha256: fixture.sha256 },
    role: fixture.role ?? "canonical",
    profileStatus: "excluded",
    legacy: fixture,
  }));
  try {
    const meta = JSON.parse(await readFile(
      path.join(goldenDirectory, osDirectory, "unified", "meta.json"), "utf8"
    ));
    for (const [section, entry] of Object.entries(meta.sections ?? {})) {
      modules.push({
        id: `core.${section}`,
        file: `unified/${entry.file}`,
        payloadSchemaVersion: meta.schemaVersion ?? 1,
        planVersion: 1,
        platform: raw.unifiedPlatform ?? raw.platform ?? null,
        capturedAt: meta.capturedAt ?? raw.capturedAt ?? null,
        capture: { environment: null, sessionID: null },
        provenance: { kind: "legacy-unified-meta" },
        coverageClaims: [],
        integrity: { sha256: entry.sha256, bytes: entry.bytes },
        statistics: { rows: entry.rows },
        role: meta.role ?? "canonical",
        profileStatus: "required",
      });
    }
  } catch {
    // A v1 archive may legitimately predate unified sections.
  }
  return { ...raw, sourceProtocolVersion: 1, modules };
}

function moduleAsLegacyFixture(module, legacyFixtures) {
  const legacy = legacyFixtures.find(
    (fixture) => fixture.id === module.provenance?.fixtureID
  ) ?? module.legacy ?? {};
  return {
    ...legacy,
    id: module.provenance?.fixtureID ?? module.id,
    file: module.file,
    sha256: module.integrity.sha256,
    schemaVersion: module.payloadSchemaVersion,
    platform: module.platform,
    capturedAt: module.capturedAt,
    role: module.role,
  };
}

export function moduleByID(manifest, id) {
  return manifest.modules.find((module) => module.id === id) ?? null;
}

export function profileModules(manifest, profileName = "full") {
  const profile = manifest.profiles?.[profileName];
  if (!profile) return null;
  return Object.fromEntries([
    ["required", profile.required.map((id) => moduleByID(manifest, id))],
    ["optional", profile.optional.map((id) => moduleByID(manifest, id))],
    ["unsupported", [...profile.unsupported]],
    ["carriedForward", profile.carriedForward.map((id) => moduleByID(manifest, id))],
  ]);
}
