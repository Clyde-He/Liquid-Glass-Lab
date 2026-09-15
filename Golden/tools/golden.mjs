#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  closeSync, existsSync, openSync, readFileSync, rmSync,
} from "node:fs";
import {
  copyFile, mkdir, mkdtemp, readFile, rename, rm, writeFile,
} from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  ARCHIVE_FILES, acceptedArchives, admitArchive, admitCoreArchive, compareArchives,
  compareStaticDocuments, copyArchive, finalizeStaging, platformFromCapture,
  validateStaticDocument, compareTransparency,
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
  golden.mjs tint-model --os macOS-27 [--check]
  golden.mjs fixtures [--check]
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

function runDriver(app, flag, destination, { transparency = false } = {}) {
  const handoff = `@temporary/golden-${process.pid}-${path.basename(destination)}`;
  const checkpoint = TINT_CHECKPOINT_FLAGS.has(flag) && existsSync(destination)
    ? readFileSync(destination) : null;
  const driverArgs = [flag, handoff, "--artifact-stdout"];
  if (transparency) {
    driverArgs.push("--golden-transparency", "-NSGlassTintAmount", "0.5");
  }
  if (checkpoint) driverArgs.push("--checkpoint-stdin");
  const stdoutPath = path.join(
    "/private/tmp",
    `.golden-driver-${process.pid}-${Date.now()}-${path.basename(destination)}.stdout`,
  );
  const stdout = openSync(stdoutPath, "w");
  let result;
  try {
    result = spawnSync(app, driverArgs, {
      input: checkpoint ?? undefined,
      stdio: [checkpoint ? "pipe" : "ignore", stdout, "inherit"],
    });
  } finally {
    closeSync(stdout);
  }
  const artifact = readFileSync(stdoutPath);
  try {
    if (result.error) throw result.error;
    if (result.status !== 0) {
      if (TINT_CHECKPOINT_FLAGS.has(flag) && artifact.length > 0) {
        try {
          importArtifactEnvelope(artifact, destination);
          console.error(`Tint checkpoint preserved after ${flag} stopped`);
        } catch {
          // The original driver failure remains the useful error.
        }
      }
      throw new Error(`${flag} exited ${result.status ?? "by signal"}`);
    }
    if (artifact.length === 0) throw new Error(`${flag} returned no artifact`);
    importArtifactEnvelope(artifact, destination);
  } finally {
    rmSync(stdoutPath, { force: true });
  }
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

  // Fail the inexpensive Core contract, including full Catalog derivation,
  // before starting the long resumable auxiliary captures.
  await admitCoreArchive(partial);

  const drivers = [
    ["--capture-tint-parameterization", ARCHIVE_FILES.tintSweep],
    ["--capture-tint-parameterization-focused", ARCHIVE_FILES.tintFocused],
    ["--capture-tint-parameterization-phase-2c", ARCHIVE_FILES.tintHue],
    ["--verify-tint-sync-resolution", ARCHIVE_FILES.tintSync],
    ["--verify-tint-wide-gamut-model", ARCHIVE_FILES.tintWideGamut],
  ];
  const captureDocument = JSON.parse(
    await readFile(path.join(partial, ARCHIVE_FILES.capture), "utf8")
  );
  const platform = platformFromCapture(captureDocument);
  const usesTransparency = platform.major === 27;
  for (const [flag, file] of drivers) {
    const destination = path.join(partial, file);
    if (!existsSync(destination)) {
      runDriver(app, flag, destination, { transparency: usesTransparency });
    }
  }
  if (platform.major >= 27) {
    const semantic = path.join(partial, ARCHIVE_FILES.semantic);
    if (!existsSync(semantic)) {
      runDriver(app, "--capture-semantic-usage-trees", semantic, {
        transparency: usesTransparency,
      });
    }
  } else {
    await rm(path.join(partial, ARCHIVE_FILES.semantic), { force: true });
  }
  await admitArchive(partial);
  await finalizeStaging(partial, output);
  console.error(`Golden capture complete: ${output}`);
}

async function archiveSetWith(staging, name) {
  const archives = (await acceptedArchives(goldenDirectory))
    .filter((archive) => archive.name !== name);
  archives.push({ name, major: Number(name.slice("macOS-".length)), directory: staging });
  archives.sort((left, right) => left.major - right.major);
  return archives;
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
  if (baselineEntry) baseline = await admitArchive(baselineEntry.directory);
  const comparison = baseline ? compareArchives(baseline, candidate) : null;
  const archives = await archiveSetWith(staging, name);
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
    },
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  const problems = releaseVerificationProblems(verification);
  if (problems.length) throw new Error(`Golden verification failed: ${problems.join("; ")}`);
  if (!args.includes("--accept")) {
    console.error("Preview only. Review the report, then rerun with --accept on this staging.");
    return;
  }

  // Install a validated copy of the reviewed staging. Capture never runs here.
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
    const problems = validateStaticDocument(staticDocument);
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
    const staticComparison = compareStaticDocuments(baseline, staticDocument);
    const transparency = compareTransparency(accepted.capture, captureDocument);
    const displaySignatureMatches =
      accepted.platform.displaySignature === platform.displaySignature;
    const report = {
      capturedOn: platform,
      accepted: accepted.platform,
      sampledObservations: staticDocument.observations.length,
      ...staticComparison,
      transparency,
      displaySignatureMatches,
      equivalent: staticComparison.equivalent
        && transparency.comparable
        && displaySignatureMatches,
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

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonical(value[key])])
    );
  }
  return value;
}

async function writeJSONAtomic(output, value) {
  const temporary = path.join(
    path.dirname(output), `.${path.basename(output)}.${process.pid}.tmp`
  );
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`);
  await rename(temporary, output);
}

async function tintModel() {
  const name = osName(option("--os", { required: true }));
  if (name !== "macOS-27") usage("The transparency model is available only for macOS-27");
  const { modelFromAcceptedArchive } = await import("./tint-amount-model.mjs");
  const value = await modelFromAcceptedArchive(path.join(goldenDirectory, name));
  const output = path.join(
    catalogDirectory, `glass-tint-amount-${name.toLowerCase()}.json`
  );
  if (args.includes("--check")) {
    const actual = JSON.parse(await readFile(output, "utf8"));
    if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(value))) {
      throw new Error("Bundled transparency model is stale");
    }
  } else {
    await writeJSONAtomic(output, value);
  }
  console.error(`Transparency model ${args.includes("--check") ? "verified" : "generated"} from accepted Golden`);
}

if (!["drift", "capture", "promote", "catalog", "tint-model", "fixtures"].includes(command)) usage();
if (command === "drift") await drift();
else if (command === "capture") await capture();
else if (command === "promote") await promote();
else if (command === "catalog") await catalog();
else if (command === "tint-model") await tintModel();
else await import("./fixtures.mjs");
