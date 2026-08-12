#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import {
  copyFile, mkdir, mkdtemp, readFile, rename, rm, writeFile,
} from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  ARCHIVE_FILES, acceptedArchives, admitArchive, compareArchives,
  compareStaticDocuments, copyArchive, finalizeStaging, platformFromCapture,
  validateStaticDocument,
} from "./lib/archive.mjs";
import { importArtifactEnvelope } from "./lib/artifact-handoff.mjs";
import { catalogBytes, catalogFromArchive } from "./lib/catalog.mjs";
import { cellKey } from "./lib/cell.mjs";
import { goldenDirectory } from "./lib/golden.mjs";
import {
  readDispositions, releaseVerificationProblems, verifyArchiveSet,
} from "./lib/verify-engine.mjs";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const catalogDirectory = path.join(
  path.dirname(goldenDirectory), "LiquidGlassLab/GlassMaterial/Catalog"
);
const command = process.argv[2];
const args = process.argv.slice(3);

function usage(message) {
  if (message) console.error(message);
  console.error(`usage:
  golden.mjs drift --app EXECUTABLE --os macOS-N [--output REPORT]
  golden.mjs capture --app EXECUTABLE --output STAGING
  golden.mjs promote --staging STAGING [--accept]
  golden.mjs catalog --os macOS-N [--output FILE | --check]`);
  process.exit(64);
}

function option(name, { required = false } = {}) {
  const joined = args.find((argument) => argument.startsWith(`${name}=`));
  if (joined) return joined.slice(name.length + 1);
  const index = args.indexOf(name);
  const value = index < 0 ? null : args[index + 1];
  if (index >= 0 && (!value || value.startsWith("--"))) usage(`${name} requires a value`);
  if (required && !value) usage(`${name} is required`);
  return value;
}

function osName(value) {
  if (!/^macOS-[0-9]+$/.test(value ?? "")) usage("--os must look like macOS-27");
  return value;
}

const TINT_CHECKPOINT_FLAGS = new Set([
  "--capture-tint-parameterization",
  "--capture-tint-parameterization-focused",
  "--capture-tint-parameterization-phase-2c",
]);

function runDriver(app, flag, destination) {
  const handoff = `@temporary/golden-${process.pid}-${path.basename(destination)}`;
  const checkpoint = TINT_CHECKPOINT_FLAGS.has(flag) && existsSync(destination)
    ? readFileSync(destination) : null;
  const driverArgs = [flag, handoff, "--artifact-stdout"];
  if (checkpoint) driverArgs.push("--checkpoint-stdin");
  const result = spawnSync(app, driverArgs, {
    encoding: "utf8", input: checkpoint ?? undefined, maxBuffer: 128 * 1024 * 1024,
  });
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    if (TINT_CHECKPOINT_FLAGS.has(flag) && result.stdout?.trim()) {
      try {
        importArtifactEnvelope(result.stdout, destination);
        console.error(`Tint checkpoint preserved after ${flag} stopped`);
      } catch {
        // The original driver failure remains the useful error.
      }
    }
    throw new Error(`${flag} exited ${result.status ?? "by signal"}`);
  }
  if (!result.stdout?.trim()) throw new Error(`${flag} returned no artifact`);
  importArtifactEnvelope(result.stdout, destination);
}

async function capture() {
  const app = path.resolve(option("--app", { required: true }));
  const output = path.resolve(option("--output", { required: true }));
  const partial = `${output}.partial`;
  const core = `${partial}.core-${process.pid}`;
  await mkdir(partial, { recursive: true });
  await rm(core, { recursive: true, force: true });
  try {
    runDriver(app, "--capture-golden", core);
    for (const file of [ARCHIVE_FILES.capture, ARCHIVE_FILES.static, ARCHIVE_FILES.dynamic]) {
      await copyFile(path.join(core, file), path.join(partial, file));
    }
  } finally {
    await rm(core, { recursive: true, force: true });
  }

  const drivers = [
    ["--capture-tint-parameterization", ARCHIVE_FILES.tintSweep],
    ["--capture-tint-parameterization-focused", ARCHIVE_FILES.tintFocused],
    ["--capture-tint-parameterization-phase-2c", ARCHIVE_FILES.tintHue],
    ["--verify-tint-sync-resolution", ARCHIVE_FILES.tintSync],
    ["--verify-tint-wide-gamut-model", ARCHIVE_FILES.tintWideGamut],
  ];
  for (const [flag, file] of drivers) runDriver(app, flag, path.join(partial, file));

  const captureDocument = JSON.parse(
    await readFile(path.join(partial, ARCHIVE_FILES.capture), "utf8")
  );
  const platform = platformFromCapture(captureDocument);
  if (platform.major >= 27) {
    runDriver(app, "--capture-semantic-usage-trees", path.join(partial, ARCHIVE_FILES.semantic));
  } else {
    await rm(path.join(partial, ARCHIVE_FILES.semantic), { force: true });
  }
  await admitArchive(partial);
  await finalizeStaging(partial, output);
  console.error(`Golden capture complete: ${output}`);
}

async function admittedSetWith(staging, name) {
  const archives = [];
  const rejected = [];
  for (const archive of await acceptedArchives(goldenDirectory)) {
    if (archive.name === name) continue;
    try {
      await admitArchive(archive.directory);
      archives.push(archive);
    } catch {
      rejected.push(archive.name);
    }
  }
  archives.push({ name, major: Number(name.slice("macOS-".length)), directory: staging });
  archives.sort((left, right) => left.major - right.major);
  return { archives, rejected };
}

async function promote() {
  const staging = path.resolve(option("--staging", { required: true }));
  const candidate = await admitArchive(staging);
  const name = `macOS-${candidate.platform.major}`;
  const target = path.join(goldenDirectory, name);
  let baseline = null;
  const installed = await acceptedArchives(goldenDirectory);
  const baselineEntry = installed.find((archive) => archive.name === name)
    ?? installed.filter(({ major }) => major < candidate.platform.major).at(-1);
  if (baselineEntry) {
    try { baseline = await admitArchive(baselineEntry.directory); } catch { baseline = null; }
  }
  const comparison = baseline ? compareArchives(baseline, candidate) : null;
  const { archives, rejected } = await admittedSetWith(staging, name);
  const verification = await verifyArchiveSet({
    archives,
    includeCrossVersion: archives.length > 1,
    dispositions: await readDispositions(),
  });
  const report = {
    candidate: { name, directory: staging, platform: candidate.platform },
    baseline: baseline ? { directory: baseline.directory, platform: baseline.platform } : null,
    comparison,
    verification: {
      tally: verification.tally,
      undispositionedSkips: verification.undispositionedSkips,
      staleDispositions: verification.staleDispositions,
      rejectedArchivesAwaitingRecapture: rejected,
    },
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  const problems = releaseVerificationProblems(verification);
  if (problems.length) throw new Error(`Golden verification failed: ${problems.join("; ")}`);
  if (!args.includes("--accept")) {
    console.error("Preview only. Review the report, then rerun with --accept on this staging.");
    return;
  }

  // Re-read the same staging, then install a validated copy. Capture never runs here.
  await admitArchive(staging);
  const transactionRoot = await mkdtemp(path.join(goldenDirectory, `.${name}.promote-`));
  const transaction = path.join(transactionRoot, name);
  try {
    await copyArchive(staging, transaction);
    await admitArchive(transaction);
    const helper = existsSync(target) ? "atomic-promote.swift" : "atomic-create.swift";
    const result = spawnSync("xcrun", [
      "swift", path.join(toolDirectory, helper), transaction, target,
    ], { stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`atomic install exited ${result.status}`);
  } finally {
    await rm(transactionRoot, { recursive: true, force: true });
  }
  console.error(`Accepted Golden installed: ${target}`);
}

async function catalog() {
  const name = osName(option("--os", { required: true }));
  const major = Number(name.slice("macOS-".length));
  const archive = await admitArchive(path.join(goldenDirectory, name));
  if (archive.platform.major !== major) throw new Error(`${name} contains macOS ${archive.platform.major}`);
  const bytes = catalogBytes(catalogFromArchive(archive));
  const output = path.resolve(option("--output")
    ?? path.join(catalogDirectory, `glass-macos-${major}.json`));
  if (args.includes("--check")) {
    const committed = await readFile(output);
    if (!committed.equals(bytes)) throw new Error(`${output} is stale; run golden catalog --os ${name}`);
    console.error(`Catalog is current: ${output}`);
    return;
  }
  const temporary = path.join(path.dirname(output), `.${path.basename(output)}.${process.pid}.tmp`);
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(temporary, bytes);
  await rename(temporary, output);
  console.error(`Catalog generated from accepted Golden: ${output}`);
}

async function drift() {
  const app = path.resolve(option("--app", { required: true }));
  const name = osName(option("--os", { required: true }));
  const accepted = await admitArchive(path.join(goldenDirectory, name));
  const captureDirectory = await mkdtemp(path.join("/private/tmp", "golden-drift-"));
  try {
    runDriver(app, "--capture-golden-drift", captureDirectory);
    const captureDocument = JSON.parse(
      await readFile(path.join(captureDirectory, ARCHIVE_FILES.capture), "utf8")
    );
    const staticDocument = JSON.parse(
      await readFile(path.join(captureDirectory, ARCHIVE_FILES.static), "utf8")
    );
    const problems = validateStaticDocument(staticDocument, {
      expectedObservationCount: 28,
      expectedConsumerCount: 24,
    });
    if (problems.length) throw new Error(`invalid drift capture: ${problems.join("; ")}`);
    const platform = platformFromCapture(captureDocument);
    if (platform.major !== accepted.platform.major) {
      throw new Error(`drift capture ran on macOS ${platform.major}, expected ${accepted.platform.major}`);
    }
    const acceptedByCell = new Map(
      accepted.static.observations.map((observation) => [
        cellKey(observation.cell), observation,
      ])
    );
    const baseline = {
      schemaVersion: 2,
      consumerCells: staticDocument.consumerCells,
      observations: staticDocument.observations.map(({ cell }) =>
        acceptedByCell.get(cellKey(cell))).filter(Boolean),
    };
    if (baseline.observations.length !== staticDocument.observations.length) {
      throw new Error("accepted Golden does not contain every drift sentinel coordinate");
    }
    const report = {
      capturedOn: platform,
      accepted: accepted.platform,
      sampledObservations: staticDocument.observations.length,
      ...compareStaticDocuments(baseline, staticDocument),
    };
    const output = option("--output");
    const text = `${JSON.stringify(report, null, 2)}\n`;
    if (output) await writeFile(path.resolve(output), text);
    process.stdout.write(text);
    if (!report.equivalent) process.exitCode = 1;
  } finally {
    await rm(captureDirectory, { recursive: true, force: true });
  }
}

if (!["drift", "capture", "promote", "catalog"].includes(command)) usage();
if (command === "drift") await drift();
else if (command === "capture") await capture();
else if (command === "promote") await promote();
else await catalog();
