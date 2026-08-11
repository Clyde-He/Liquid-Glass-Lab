#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { copyFile, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { validateManifestV2 } from "./lib/manifest.mjs";
import {
  CLAIMS, FULL_DRIVERS as FULL, FULL_MODULE_IDS as REQUIRED,
  PROFILE_DEFINITION_VERSION, payloadModule, platformFrom, profileForMajor,
  validateFullDirectory,
} from "./lib/profile.mjs";
const TINT_CHECKPOINT_FILES = FULL.slice(1, 4).map(([, , file]) => file);
const TINT_CHECKPOINT_FLAGS = new Set(FULL.slice(1, 4).map(([, flag]) => flag));
const toolDirectory = path.dirname(fileURLToPath(import.meta.url));

function usage() {
  console.error("usage: capture-profile.mjs <full|drift-scan> --app APP --output DIR [--accepted DIR] [--promote]");
  process.exit(64);
}
function option(name) {
  const index = process.argv.indexOf(name);
  return index < 0 ? null : process.argv[index + 1];
}
function run(app, flag, destination) {
  const handoff = `@temporary/${process.pid}-${path.basename(destination)}`;
  const checkpoint = existsSync(destination) && statSync(destination).isFile()
    ? readFileSync(destination) : undefined;
  const args = [flag, handoff];
  if (checkpoint) args.push("--checkpoint-stdin");
  const result = spawnSync(app, args, { encoding: "utf8", input: checkpoint });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  const artifact = /^GLASS_LAB_ARTIFACT_PATH=(.+)$/m.exec(result.stderr ?? "")?.[1];
  if (result.status !== 0) {
    if (TINT_CHECKPOINT_FLAGS.has(flag) && artifact && existsSync(artifact)) {
      rmSync(destination, { recursive: true, force: true });
      mkdirSync(path.dirname(destination), { recursive: true });
      cpSync(artifact, destination, { force: true });
      rmSync(artifact, { force: true });
      process.stderr.write(`Recovered Tint checkpoint after ${flag} failure\n`);
    }
    throw new Error(`${flag} exited ${result.status ?? "by signal"}`);
  }
  if (!artifact) throw new Error(`${flag} did not report an artifact path`);
  rmSync(destination, { recursive: true, force: true });
  mkdirSync(path.dirname(destination), { recursive: true });
  cpSync(artifact, destination, { recursive: true, force: true });
  rmSync(artifact, { recursive: true, force: true });
}
function stripDynamicVolatileFields(value) {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) stripDynamicVolatileFields(item);
    return;
  }
  delete value.inputMaxHeadroom;
  for (const child of Object.values(value)) stripDynamicVolatileFields(child);
}
function normalizedDynamicRuns(runs) {
  const problems = [];
  const normalized = structuredClone(runs ?? []);
  for (const [runIndex, run] of normalized.entries()) {
    delete run.maximumAttachedAnimationDuration;
    for (const [sampleIndex, sample] of (run.samples ?? []).entries()) {
      delete sample.elapsed;
      stripDynamicVolatileFields(sample);
      if (Number.isFinite(sample.progress) && Number.isFinite(sample.requestedProgress)) {
        const delta = Math.abs(sample.progress - sample.requestedProgress);
        if (delta <= 0.02) sample.progress = sample.requestedProgress;
        else problems.push(`run ${runIndex} sample ${sampleIndex}: progress delta ${delta}`);
      }
    }
  }
  return { normalized, problems };
}
function firstDifference(lhs, rhs, path = "runs") {
  if (Object.is(lhs, rhs)) return null;
  if (typeof lhs !== "object" || lhs === null
      || typeof rhs !== "object" || rhs === null) {
    return `${path}: ${JSON.stringify(lhs)} != ${JSON.stringify(rhs)}`;
  }
  const lhsKeys = Object.keys(lhs);
  const rhsKeys = Object.keys(rhs);
  if (JSON.stringify(lhsKeys) !== JSON.stringify(rhsKeys)) {
    return `${path}: keys ${JSON.stringify(lhsKeys)} != ${JSON.stringify(rhsKeys)}`;
  }
  for (const key of lhsKeys) {
    const difference = firstDifference(lhs[key], rhs[key], `${path}.${key}`);
    if (difference) return difference;
  }
  return null;
}
async function buildManifest(root, accepted) {
  const metaBytes = await readFile(path.join(root, "unified/meta.json"));
  const meta = JSON.parse(metaBytes);
  const platform = platformFrom(meta.operatingSystem ?? "");
  const osMajor = Number.parseInt(platform.version, 10);
  const { required, optional, unsupported } = profileForMajor(osMajor);
  const modules = [];
  for (const [section, entry] of Object.entries(meta.sections ?? {})) {
    modules.push({
      id: `core.${section}`, file: `unified/${entry.file}`,
      payloadSchemaVersion: meta.schemaVersion ?? 1, planVersion: PROFILE_DEFINITION_VERSION, platform,
      capturedAt: meta.capturedAt, capture: { environment: null, sessionID: null },
      provenance: { kind: "direct-capture", payloadMetadata: "unified/meta.json" },
      coverageClaims: CLAIMS[`core.${section}`],
      integrity: { sha256: entry.sha256, bytes: entry.bytes },
      statistics: { rows: entry.rows, repeatedCells: entry.repeatedCells ?? 0, slices: entry.slices ?? {} },
      role: "canonical", profileStatus: "required",
    });
  }
  for (const [id, , file] of FULL.slice(1)) {
    let module;
    try {
      module = await payloadModule(root, id, file);
    } catch (error) {
      if (optional.includes(id) && error?.code === "ENOENT") continue;
      throw error;
    }
    if (optional.includes(id)) module.profileStatus = "optional";
    modules.push(module);
  }
  const carriedForward = [];
  if (accepted) {
    const old = JSON.parse(await readFile(path.join(accepted, "manifest.json")));
    for (const oldModule of old.modules ?? []) {
      if (REQUIRED.includes(oldModule.id)) continue;
      const target = path.join(root, oldModule.file);
      await mkdir(path.dirname(target), { recursive: true });
      await copyFile(path.join(accepted, oldModule.file), target);
      modules.push(oldModule);
      if (oldModule.profileStatus === "carried-forward") carriedForward.push(oldModule.id);
    }
  }
  const ids = new Set(modules.map(({ id }) => id));
  const missing = required.filter((id) => !ids.has(id));
  if (missing.length) throw new Error(`incomplete Full staging: ${missing.join(", ")}`);
  const builds = [...new Set(modules.filter(({ id }) => required.includes(id)).map(({ platform }) => platform.build))];
  if (modules.some(({ id, platform }) => required.includes(id)
      && Object.values(platform).some((value) => value === "unknown"))) {
    throw new Error("Full platform provenance is incomplete");
  }
  if (builds.length !== 1) throw new Error(`Full must be single-build; got ${builds.join(", ")}`);
  const manifest = {
    protocolVersion: 2, status: "staged", platform, capturedAt: meta.capturedAt,
    modules, profiles: { full: {
      required, optional, unsupported, carriedForward,
      captureBuildPolicy: "single-build", builds,
    } },
  };
  const problems = validateManifestV2(manifest);
  if (problems.length) throw new Error(`invalid staged manifest: ${problems.join("; ")}`);
  await writeFile(path.join(root, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
}
async function validateStagingIntegrity(root) {
  const { problems } = await validateFullDirectory(root, { expectedStatus: "staged" });
  if (problems.length) throw new Error(`invalid Full staging: ${problems.join("; ")}`);
}
async function recreateStagingPreservingTintCheckpoints(staging) {
  const resume = `${staging}.resume-${process.pid}`;
  await rm(resume, { recursive: true, force: true });
  await mkdir(resume, { recursive: true });
  for (const file of TINT_CHECKPOINT_FILES) {
    try {
      const bytes = await readFile(path.join(staging, file));
      JSON.parse(bytes.toString("utf8"));
      await copyFile(path.join(staging, file), path.join(resume, file));
    } catch (error) {
      if (error?.code !== "ENOENT") throw new Error(`invalid Tint checkpoint ${file}: ${error.message}`);
    }
  }
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  for (const file of TINT_CHECKPOINT_FILES) {
    try {
      await copyFile(path.join(resume, file), path.join(staging, file));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  await rm(resume, { recursive: true, force: true });
}
async function promote(staging, accepted) {
  if (!accepted) throw new Error("--promote requires --accepted");
  await validateStagingIntegrity(staging);
  const previous = JSON.parse(await readFile(path.join(accepted, "manifest.json")));
  const previousRequired = previous.profiles?.full?.required ?? [];
  const stagedPath = path.join(staging, "manifest.json");
  const staged = JSON.parse(await readFile(stagedPath));
  const samePlatform = previous.platform?.product === staged.platform?.product
    && Number.parseInt(previous.platform?.version, 10)
      === Number.parseInt(staged.platform?.version, 10)
    && previous.platform?.architecture === staged.platform?.architecture;
  if (!samePlatform) {
    throw new Error("promotion target product, OS major, or architecture does not match staging");
  }
  if (JSON.stringify(previousRequired) !== JSON.stringify(staged.profiles.full.required)) {
    throw new Error(
      "initial post-refactor promotion gate failed: accepted Full coverage differs from the registered profile"
    );
  }
  const comparisons = [];
  let equivalent = true;
  for (const id of staged.profiles.full.required.filter((id) => id !== "core.dynamic")) {
    const slices = id === "core.static-tree" ? ["core", "repeat", "appearance"] : [null];
    for (const slice of slices) {
      const args = [
        path.join(toolDirectory, "compare.mjs"), accepted, staging,
        `--module=${id}`, "--limit=20",
      ];
      if (id.startsWith("tint.")) args.push("--tint-mode=values");
      if (slice) args.push(`--baseline-slice=${slice}`, `--candidate-slice=${slice}`);
      const result = spawnSync(process.execPath, args, { encoding: "utf8" });
      if (result.status !== 0) throw new Error(`equivalence comparison failed for ${id}: ${result.stderr}`);
      const report = JSON.parse(result.stdout);
      comparisons.push({ id, slice, summary: report.summary });
      const summary = report.summary;
      if ([
        "missingRows", "addedRows", "missingPasses", "addedPasses",
        "missingFields", "addedFields", "changedValues",
        "topologyChangedRows", "valueChangedRows",
      ].some((field) => (summary[field] ?? 0) !== 0)) equivalent = false;
    }
  }
  const oldDynamicFile = previous.modules.find(({ id }) => id === "core.dynamic")?.file;
  const newDynamicFile = staged.modules.find(({ id }) => id === "core.dynamic")?.file;
  const oldDynamic = JSON.parse(await readFile(path.join(accepted, oldDynamicFile)));
  const newDynamic = JSON.parse(await readFile(path.join(staging, newDynamicFile)));
  const oldNormalized = normalizedDynamicRuns(oldDynamic.runs);
  const newNormalized = normalizedDynamicRuns(newDynamic.runs);
  const dynamicProblems = [...oldNormalized.problems, ...newNormalized.problems];
  const durationDeltas = (oldDynamic.runs ?? []).map((run, index) => {
    const baseline = run.maximumAttachedAnimationDuration;
    const candidate = newDynamic.runs?.[index]?.maximumAttachedAnimationDuration;
    if (!Number.isFinite(baseline) || !Number.isFinite(candidate)) {
      dynamicProblems.push(
        `run ${index}: maximumAttachedAnimationDuration must be finite on both sides`
      );
      return Number.POSITIVE_INFINITY;
    }
    return Math.abs(baseline - candidate);
  });
  if (durationDeltas.some((delta) => delta > 0.05)) {
    dynamicProblems.push(`maximum animation duration delta ${Math.max(...durationDeltas)}`);
  }
  const payloadDifference = firstDifference(
    oldNormalized.normalized,
    newNormalized.normalized
  );
  if (payloadDifference) dynamicProblems.push(payloadDifference);
  const dynamicEquivalent = dynamicProblems.length === 0;
  if (!dynamicEquivalent) equivalent = false;
  comparisons.push({
    id: "core.dynamic", equivalent: dynamicEquivalent,
    baselineRuns: oldDynamic.runs?.length ?? null,
    candidateRuns: newDynamic.runs?.length ?? null,
    maximumAnimationDurationDelta: Math.max(0, ...durationDeltas),
    problems: dynamicProblems,
  });
  await writeFile(`${staging}.equivalence.json`, `${JSON.stringify({ equivalent, comparisons }, null, 2)}\n`);
  if (!equivalent && !process.argv.includes("--accept-drift")) {
    throw new Error(`Full value equivalence failed; inspect ${staging}.equivalence.json and rerun with --accept-drift after approval`);
  }
  staged.status = "accepted";
  await writeFile(stagedPath, `${JSON.stringify(staged, null, 2)}\n`);
  const result = spawnSync("xcrun", [
    "swift", path.join(toolDirectory, "atomic-promote.swift"), staging, accepted,
  ], { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`atomic promotion exited ${result.status}`);
}

const profile = process.argv[2];
const app = option("--app");
const output = option("--output");
const accepted = option("--accepted");
if (!app || !output || !["full", "drift-scan"].includes(profile)) usage();

if (profile === "drift-scan") {
  const staging = `${output}.drift-staging-${process.pid}`;
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  run(app, "--verify-style-atlas", path.join(staging, "style-atlas.json"));
  run(app, "--verify-tint-sync-resolution", path.join(staging, "tint-sync-resolution.json"));
  for (const file of ["style-atlas.json", "tint-sync-resolution.json"]) {
    JSON.parse(await readFile(path.join(staging, file), "utf8"));
  }
  await writeFile(path.join(staging, "profile.json"), `${JSON.stringify({
    profile: "drift-scan", canonical: false, promotable: false,
    modules: ["drift.style-atlas", "drift.tint-sync"],
  }, null, 2)}\n`);
  await rm(output, { recursive: true, force: true });
  await rename(staging, output);
  console.error(`Drift Scan complete (noncanonical): ${output}`);
} else {
  const staging = `${output}.full-staging`;
  await recreateStagingPreservingTintCheckpoints(staging);
  const [, coreFlag, coreRelative] = FULL[0];
  run(app, coreFlag, path.join(staging, coreRelative));
  for (const [, flag, relative] of FULL.slice(1)) {
    const destination = path.join(staging, relative);
    // Tint sweep drivers resume from their own per-color checkpoints. The
    // other drivers deliberately rerun: a merely present file is not proof
    // that a module passed its current completeness gates.
    run(app, flag, destination);
  }
  await buildManifest(staging, accepted);
  await validateStagingIntegrity(staging);
  if (process.argv.includes("--promote")) await promote(staging, accepted);
  else console.error(`Full capture staged, validated, and not promoted: ${staging}`);
}
