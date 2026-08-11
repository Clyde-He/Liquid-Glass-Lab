#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const FULL = [
  ["core", "--capture-golden", "unified"],
  ["tint.parameterization.sweep", "--capture-tint-parameterization", "tint-parameterization-sweep.json"],
  ["tint.parameterization.focused-2b", "--capture-tint-parameterization-focused", "tint-parameterization-focused-phase-2b.json"],
  ["tint.parameterization.hue-2c", "--capture-tint-parameterization-phase-2c", "tint-parameterization-hue-phase-2c.json"],
  ["tint.sync-resolution", "--verify-tint-sync-resolution", "tint-sync-resolution.json"],
  ["tint.wide-gamut", "--verify-tint-wide-gamut-model", "tint-wide-gamut-model.json"],
  ["semantic.usage-trees", "--capture-semantic-usage-trees", "semantic-usage-trees.json"],
];
const REQUIRED = [
  "core.static-scalar", "core.static-tree", "core.dynamic",
  ...FULL.slice(1).map(([id]) => id),
];
const CLAIMS = {
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

function usage() {
  console.error("usage: capture-profile.mjs <full|drift-scan> --app APP --output DIR [--accepted DIR] [--promote]");
  process.exit(64);
}
function option(name) {
  const index = process.argv.indexOf(name);
  return index < 0 ? null : process.argv[index + 1];
}
function run(app, flag, destination) {
  const result = spawnSync(app, [flag, destination], { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${flag} exited ${result.status}`);
}
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
function platformFrom(operatingSystem) {
  const version = /Version ([0-9.]+)/.exec(operatingSystem)?.[1]
    ?? /macOS ([0-9.]+)/.exec(operatingSystem)?.[1] ?? "unknown";
  const build = /Build ([^)]+)/.exec(operatingSystem)?.[1] ?? "unknown";
  return { product: "macOS", version, build, architecture: process.arch };
}
async function payloadModule(root, id, file) {
  const bytes = await readFile(path.join(root, file));
  const payload = JSON.parse(bytes);
  const capturedAt = payload.capturedAt ?? payload.generatedAt ?? null;
  return {
    id, file, payloadSchemaVersion: payload.formatVersion ?? payload.schemaVersion ?? 1,
    planVersion: 1, platform: platformFrom(payload.operatingSystem ?? ""), capturedAt,
    capture: { environment: payload.environment ?? payload.context ?? null, sessionID: payload.sessionID ?? null },
    provenance: { kind: "direct-capture" }, coverageClaims: CLAIMS[id],
    integrity: { sha256: sha256(bytes), bytes: bytes.length }, role: "canonical",
    profileStatus: "required",
  };
}
async function buildManifest(root, accepted) {
  const metaBytes = await readFile(path.join(root, "unified/meta.json"));
  const meta = JSON.parse(metaBytes);
  const platform = platformFrom(meta.operatingSystem ?? "");
  const modules = [];
  for (const [section, entry] of Object.entries(meta.sections ?? {})) {
    modules.push({
      id: `core.${section}`, file: `unified/${entry.file}`,
      payloadSchemaVersion: meta.schemaVersion ?? 1, planVersion: 1, platform,
      capturedAt: meta.capturedAt, capture: { environment: null, sessionID: null },
      provenance: { kind: "direct-capture", payloadMetadata: "unified/meta.json" },
      coverageClaims: CLAIMS[`core.${section}`],
      integrity: { sha256: entry.sha256, bytes: entry.bytes },
      statistics: { rows: entry.rows, repeatedCells: entry.repeatedCells ?? 0, slices: entry.slices ?? {} },
      role: "canonical", profileStatus: "required",
    });
  }
  for (const [id, , file] of FULL.slice(1)) modules.push(await payloadModule(root, id, file));
  const carriedForward = [];
  if (accepted) {
    const old = JSON.parse(await readFile(path.join(accepted, "manifest.json")));
    for (const oldModule of old.modules ?? []) {
      if (oldModule.profileStatus !== "carried-forward") continue;
      await copyFile(path.join(accepted, oldModule.file), path.join(root, oldModule.file));
      modules.push(oldModule);
      carriedForward.push(oldModule.id);
    }
  }
  const ids = new Set(modules.map(({ id }) => id));
  const missing = REQUIRED.filter((id) => !ids.has(id));
  if (missing.length) throw new Error(`incomplete Full staging: ${missing.join(", ")}`);
  const builds = [...new Set(modules.filter(({ id }) => REQUIRED.includes(id)).map(({ platform }) => platform.build))];
  if (modules.some(({ id, platform }) => REQUIRED.includes(id)
      && Object.values(platform).some((value) => value === "unknown"))) {
    throw new Error("Full platform provenance is incomplete");
  }
  if (builds.length !== 1) throw new Error(`Full must be single-build; got ${builds.join(", ")}`);
  const manifest = {
    protocolVersion: 2, status: "staged", platform, capturedAt: meta.capturedAt,
    modules, profiles: { full: {
      required: REQUIRED, optional: [], unsupported: [], carriedForward,
      captureBuildPolicy: "single-build", builds,
    } },
  };
  await writeFile(path.join(root, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}
async function promote(staging, accepted) {
  if (!accepted) throw new Error("--promote requires --accepted");
  const previous = JSON.parse(await readFile(path.join(accepted, "manifest.json")));
  const previousRequired = previous.profiles?.full?.required ?? [];
  if (JSON.stringify(previousRequired) !== JSON.stringify(REQUIRED)) {
    throw new Error(
      "initial post-refactor promotion gate failed: accepted Full coverage differs from the registered profile"
    );
  }
  const backup = `${accepted}.previous`;
  await rm(backup, { recursive: true, force: true });
  try {
    await rename(accepted, backup);
    await rename(staging, accepted);
  } catch (error) {
    try { await rename(backup, accepted); } catch {}
    throw error;
  }
  await rm(backup, { recursive: true, force: true });
}

const profile = process.argv[2];
const app = option("--app");
const output = option("--output");
const accepted = option("--accepted");
if (!app || !output || !["full", "drift-scan"].includes(profile)) usage();

if (profile === "drift-scan") {
  await mkdir(output, { recursive: true });
  run(app, "--verify-style-atlas", path.join(output, "style-atlas.json"));
  run(app, "--verify-tint-sync-resolution", path.join(output, "tint-sync-resolution.json"));
  await writeFile(path.join(output, "profile.json"), `${JSON.stringify({
    profile: "drift-scan", canonical: false, promotable: false,
    modules: ["drift.style-atlas", "drift.tint-sync"],
  }, null, 2)}\n`);
  console.error(`Drift Scan complete (noncanonical): ${output}`);
} else {
  const staging = `${output}.full-staging`;
  await mkdir(staging, { recursive: true });
  for (const [, flag, relative] of FULL) {
    const destination = path.join(staging, relative);
    // Tint sweep drivers resume from their own per-color checkpoints. The
    // other drivers deliberately rerun: a merely present file is not proof
    // that a module passed its current completeness gates.
    run(app, flag, destination);
  }
  await buildManifest(staging, accepted);
  if (process.argv.includes("--promote")) await promote(staging, accepted);
  else console.error(`Full capture staged, validated, and not promoted: ${staging}`);
}
