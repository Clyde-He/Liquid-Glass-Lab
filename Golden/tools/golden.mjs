#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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
  validateCaptureDocument, validateDynamicDocument, validateStaticDocument,
  compareTransparency,
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

function runDriver(
  app, flag, destination, { transparency = false, extraArgs = [] } = {},
) {
  const handoff = `@temporary/golden-${process.pid}-${path.basename(destination)}`;
  const checkpoint = TINT_CHECKPOINT_FLAGS.has(flag) && existsSync(destination)
    ? readFileSync(destination) : null;
  const driverArgs = [flag, handoff, ...extraArgs, "--artifact-stdout"];
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

const STATIC_CHUNK_SIZE = 100;
const DYNAMIC_BATCH_CHUNK_SIZE = 12;

function queryCapturePlan(app) {
  const result = spawnSync(app, ["--print-golden-plan", "--plan-json"], {
    encoding: "utf8",
  });
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`--print-golden-plan exited ${result.status ?? "by signal"}`);
  }
  let plan;
  try {
    plan = JSON.parse(result.stdout.trim());
  } catch (error) {
    throw new Error(`--print-golden-plan returned invalid JSON: ${error.message}`);
  }
  const counts = plan?.dynamicBatchRunCounts;
  if (plan?.schemaVersion !== 1 || !Number.isInteger(plan.osMajor)
      || !Number.isInteger(plan.staticObservations) || plan.staticObservations <= 0
      || !Number.isInteger(plan.dynamicRuns) || plan.dynamicRuns <= 0
      || !Array.isArray(counts) || counts.length === 0
      || counts.some((count) => !Number.isInteger(count) || count <= 0)
      || counts.reduce((sum, count) => sum + count, 0) !== plan.dynamicRuns
      || !plan.staticLabelFirstIndices
      || Object.values(plan.staticLabelFirstIndices).some(
        (index) => !Number.isInteger(index) || index < 0
          || index >= plan.staticObservations,
      )) {
    throw new Error("--print-golden-plan returned an invalid checkpoint plan");
  }
  return plan;
}

function ranges(total, size) {
  const values = [];
  for (let start = 0; start < total; start += size) {
    values.push({ start, count: Math.min(size, total - start) });
  }
  return values;
}

function captureIdentity(capture) {
  return {
    schemaVersion: capture?.schemaVersion ?? null,
    operatingSystem: capture?.operatingSystem ?? null,
    architecture: capture?.architecture ?? null,
    displaySignature: capture?.displaySignature ?? null,
    transparency: capture?.transparency ?? null,
  };
}

function assertMatchingCapture(reference, candidate, label) {
  if (JSON.stringify(captureIdentity(reference))
      !== JSON.stringify(captureIdentity(candidate))) {
    throw new Error(`${label} was captured in a different OS/build/display/transparency context`);
  }
}

async function readStaticCheckpoint(directory, expectedCount, osMajor) {
  const [capture, document] = await Promise.all([
    readFile(path.join(directory, ARCHIVE_FILES.capture), "utf8").then(JSON.parse),
    readFile(path.join(directory, ARCHIVE_FILES.static), "utf8").then(JSON.parse),
  ]);
  const problems = [
    ...validateCaptureDocument(capture, document),
    ...validateStaticDocument(document, { requireConsumerCells: false }),
  ];
  if (document?.observations?.length !== expectedCount) {
    problems.push(`expected ${expectedCount} Static observations; got ${document?.observations?.length ?? 0}`);
  }
  if (platformFromCapture(capture).major !== osMajor) {
    problems.push(`captured macOS major differs from plan ${osMajor}`);
  }
  if (problems.length) throw new Error(problems.join("; "));
  return { capture, document };
}

async function readDynamicCheckpoint(directory, expectedCount, osMajor) {
  const [capture, document] = await Promise.all([
    readFile(path.join(directory, ARCHIVE_FILES.capture), "utf8").then(JSON.parse),
    readFile(path.join(directory, ARCHIVE_FILES.dynamic), "utf8").then(JSON.parse),
  ]);
  const problems = [
    ...validateCaptureDocument(capture),
    ...validateDynamicDocument(document, capture, { expectedRuns: expectedCount }),
  ];
  if (platformFromCapture(capture).major !== osMajor) {
    problems.push(`captured macOS major differs from plan ${osMajor}`);
  }
  if (problems.length) throw new Error(problems.join("; "));
  return { capture, document };
}

async function writeCompactJSONAtomic(output, value) {
  const temporary = path.join(
    path.dirname(output), `.${path.basename(output)}.${process.pid}.tmp`,
  );
  await writeFile(temporary, `${JSON.stringify(value)}\n`);
  await rename(temporary, output);
}

function duration(seconds) {
  if (!Number.isFinite(seconds)) return "unknown";
  const rounded = Math.max(0, Math.round(seconds));
  const hours = Math.floor(rounded / 3600);
  const minutes = Math.floor((rounded % 3600) / 60);
  const remainder = rounded % 60;
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m ${remainder}s`;
}

async function captureCore(app, partial) {
  const coreFiles = [ARCHIVE_FILES.capture, ARCHIVE_FILES.static, ARCHIVE_FILES.dynamic];
  const plan = queryCapturePlan(app);
  const checkpointRoot = path.join(partial, ".core-checkpoints");
  const manifestFile = path.join(checkpointRoot, "manifest.json");
  const hasher = createHash("sha256");
  hasher.update(await readFile(app));
  const debugLibrary = path.join(
    path.dirname(app), `${path.basename(app)}.debug.dylib`,
  );
  if (existsSync(debugLibrary)) hasher.update(await readFile(debugLibrary));
  const fingerprint = hasher.digest("hex");
  const manifest = {
    schemaVersion: 1,
    appFingerprint: fingerprint,
    staticChunkSize: STATIC_CHUNK_SIZE,
    dynamicBatchChunkSize: DYNAMIC_BATCH_CHUNK_SIZE,
    plan,
  };
  let reusable = false;
  if (existsSync(manifestFile)) {
    try {
      reusable = JSON.stringify(JSON.parse(await readFile(manifestFile, "utf8")))
        === JSON.stringify(manifest);
    } catch {
      reusable = false;
    }
  }
  if (!reusable) {
    await rm(checkpointRoot, { recursive: true, force: true });
    await Promise.all(coreFiles.map((file) => rm(
      path.join(partial, file), { force: true },
    )));
    await mkdir(checkpointRoot, { recursive: true });
    await writeCompactJSONAtomic(manifestFile, manifest);
  } else {
    console.error("Golden Core checkpoint manifest matches; validating saved chunks");
  }

  if (reusable && coreFiles.every((file) => existsSync(path.join(partial, file)))) {
    try {
      await admitCoreArchive(partial);
      console.error("Golden Core already admitted; resuming auxiliary capture");
      return;
    } catch (error) {
      console.error(`Existing Golden Core is incomplete: ${error.message}`);
      await Promise.all(coreFiles.map((file) => rm(
        path.join(partial, file), { force: true },
      )));
    }
  }

  const staticChunks = ranges(plan.staticObservations, STATIC_CHUNK_SIZE).map(
    (range, index) => ({
      ...range,
      index,
      directory: path.join(checkpointRoot, `static-${String(index).padStart(4, "0")}`),
    }),
  );
  const preferredLabels = [
    "glass-tint-interaction",
    "glass-clear-key-boundary",
    "glass-nonconsumer-sentinel",
    "glass-scale",
    "glass-geometry",
    "glass-model-anchor",
    ...Object.keys(plan.staticLabelFirstIndices).sort(),
  ];
  const priorityChunks = [...new Set(preferredLabels.map((label) =>
    plan.staticLabelFirstIndices[label]).filter(Number.isInteger).map((index) =>
    Math.floor(index / STATIC_CHUNK_SIZE)))];
  const priority = new Map(priorityChunks.map((index, rank) => [index, rank]));
  const staticCaptureOrder = [...staticChunks].sort((left, right) => {
    const leftPriority = priority.get(left.index) ?? Number.MAX_SAFE_INTEGER;
    const rightPriority = priority.get(right.index) ?? Number.MAX_SAFE_INTEGER;
    return leftPriority - rightPriority || left.index - right.index;
  });
  const startedAt = Date.now();
  let newlyCaptured = 0;
  let completed = 0;
  let referenceCapture = null;
  for (const chunk of staticCaptureOrder) {
    let saved = null;
    if (existsSync(chunk.directory)) {
      try {
        saved = await readStaticCheckpoint(chunk.directory, chunk.count, plan.osMajor);
      } catch (error) {
        console.error(`Discarding invalid Static checkpoint ${chunk.index + 1}: ${error.message}`);
        await rm(chunk.directory, { recursive: true, force: true });
      }
    }
    if (!saved) {
      console.error(
        `Golden Static chunk ${chunk.index + 1}/${staticChunks.length}: rows ${chunk.start + 1}-${chunk.start + chunk.count}`,
      );
      runDriver(app, "--capture-golden-static-chunk", chunk.directory, {
        extraArgs: ["--golden-start", String(chunk.start), "--golden-count", String(chunk.count)],
      });
      saved = await readStaticCheckpoint(chunk.directory, chunk.count, plan.osMajor);
      newlyCaptured += chunk.count;
    } else {
      console.error(`Golden Static chunk ${chunk.index + 1}/${staticChunks.length}: resumed`);
    }
    if (referenceCapture) assertMatchingCapture(referenceCapture, saved.capture, `Static chunk ${chunk.index + 1}`);
    else referenceCapture = saved.capture;
    completed += chunk.count;
    const elapsed = (Date.now() - startedAt) / 1000;
    const remaining = plan.staticObservations - completed;
    const eta = newlyCaptured > 0 ? elapsed / newlyCaptured * remaining : Number.NaN;
    console.error(
      `Golden Static overall: ${completed}/${plan.staticObservations}; elapsed ${duration(elapsed)}; ETA ${duration(eta)}`,
    );
  }

  const batchRanges = ranges(
    plan.dynamicBatchRunCounts.length, DYNAMIC_BATCH_CHUNK_SIZE,
  );
  const dynamicChunks = batchRanges.map((range, index) => ({
    ...range,
    index,
    expectedRuns: plan.dynamicBatchRunCounts
      .slice(range.start, range.start + range.count)
      .reduce((sum, count) => sum + count, 0),
    directory: path.join(checkpointRoot, `dynamic-${String(index).padStart(4, "0")}`),
  }));
  const dynamicStartedAt = Date.now();
  let dynamicNewRuns = 0;
  let dynamicCompleted = 0;
  for (const chunk of dynamicChunks) {
    let saved = null;
    if (existsSync(chunk.directory)) {
      try {
        saved = await readDynamicCheckpoint(
          chunk.directory, chunk.expectedRuns, plan.osMajor,
        );
      } catch (error) {
        console.error(`Discarding invalid Dynamic checkpoint ${chunk.index + 1}: ${error.message}`);
        await rm(chunk.directory, { recursive: true, force: true });
      }
    }
    if (!saved) {
      console.error(
        `Golden Dynamic chunk ${chunk.index + 1}/${dynamicChunks.length}: batches ${chunk.start + 1}-${chunk.start + chunk.count}`,
      );
      runDriver(app, "--capture-golden-dynamic-chunk", chunk.directory, {
        extraArgs: ["--golden-start", String(chunk.start), "--golden-count", String(chunk.count)],
      });
      saved = await readDynamicCheckpoint(
        chunk.directory, chunk.expectedRuns, plan.osMajor,
      );
      dynamicNewRuns += chunk.expectedRuns;
    } else {
      console.error(`Golden Dynamic chunk ${chunk.index + 1}/${dynamicChunks.length}: resumed`);
    }
    assertMatchingCapture(referenceCapture, saved.capture, `Dynamic chunk ${chunk.index + 1}`);
    dynamicCompleted += chunk.expectedRuns;
    const elapsed = (Date.now() - dynamicStartedAt) / 1000;
    const remaining = plan.dynamicRuns - dynamicCompleted;
    const eta = dynamicNewRuns > 0 ? elapsed / dynamicNewRuns * remaining : Number.NaN;
    console.error(
      `Golden Dynamic overall: ${dynamicCompleted}/${plan.dynamicRuns}; elapsed ${duration(elapsed)}; ETA ${duration(eta)}`,
    );
  }

  const staticDocuments = await Promise.all(staticChunks.map((chunk) =>
    readStaticCheckpoint(chunk.directory, chunk.count, plan.osMajor)));
  const dynamicDocuments = await Promise.all(dynamicChunks.map((chunk) =>
    readDynamicCheckpoint(chunk.directory, chunk.expectedRuns, plan.osMajor)));
  for (const [index, saved] of [...staticDocuments, ...dynamicDocuments].entries()) {
    assertMatchingCapture(referenceCapture, saved.capture, `Core checkpoint ${index + 1}`);
  }
  const staticDocument = {
    schemaVersion: 2,
    consumerCells: staticDocuments.flatMap(({ document }) => document.consumerCells),
    observations: staticDocuments.flatMap(({ document }) => document.observations),
  };
  const dynamicDocument = {
    schemaVersion: 2,
    runs: dynamicDocuments.flatMap(({ document }) => document.runs),
  };
  await Promise.all([
    writeCompactJSONAtomic(path.join(partial, ARCHIVE_FILES.capture), referenceCapture),
    writeCompactJSONAtomic(path.join(partial, ARCHIVE_FILES.static), staticDocument),
    writeCompactJSONAtomic(path.join(partial, ARCHIVE_FILES.dynamic), dynamicDocument),
  ]);
  await admitCoreArchive(partial);
  console.error("Golden Core merged and admitted; checkpoints remain until final admission");
}

async function capture() {
  const app = path.resolve(option("--app", { required: true }));
  const output = path.resolve(option("--output", { required: true }));
  const partial = `${output}.partial`;
  await mkdir(partial, { recursive: true });
  await captureCore(app, partial);

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
  const final = `${partial}.final-${process.pid}`;
  await rm(final, { recursive: true, force: true });
  try {
    await mkdir(final, { recursive: true });
    for (const file of Object.values(ARCHIVE_FILES)) {
      if (existsSync(path.join(partial, file))) {
        await copyFile(path.join(partial, file), path.join(final, file));
      }
    }
    await admitArchive(final);
    await finalizeStaging(final, output);
    await rm(partial, { recursive: true, force: true });
  } finally {
    await rm(final, { recursive: true, force: true });
  }
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
