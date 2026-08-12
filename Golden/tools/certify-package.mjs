#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  archiveInventory, assertCleanGitState, repositoryRoot, resolveExternalOutputPath,
} from "./lib/bootstrap.mjs";
import { goldenDirectory } from "./lib/golden.mjs";
import { validateCatalogFile, packageResourceProblems } from "./lib/catalog-certification.mjs";
import { sha256, validateFullDirectory } from "./lib/profile.mjs";
import {
  readDispositions, releaseVerificationProblems, verifyArchiveSet,
} from "./lib/verify-engine.mjs";

const args = process.argv.slice(2);
const osName = option("--os");
const reportPath = option("--report");

function option(name) {
  const joined = args.find((argument) => argument.startsWith(`${name}=`));
  if (joined) return joined.slice(name.length + 1);
  const index = args.indexOf(name);
  if (index < 0) return null;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) usage(`${name} requires a value`);
  return value;
}

function usage(message) {
  if (message) console.error(message);
  console.error("usage: certify-package.mjs --os macOS-N [--report FILE]");
  process.exit(64);
}

const match = /^macOS-([0-9]+)$/.exec(osName ?? "");
if (!match) usage("--os must use the exact macOS-N form");
const reportDestination = reportPath ? await resolveExternalOutputPath(reportPath) : null;
const major = Number(match[1]);
const golden = path.join(goldenDirectory, osName);
const catalog = path.join(repositoryRoot, `LiquidGlassLab/GlassMaterial/Catalog/glass-macos-${major}.json`);
const scratch = await mkdtemp(path.join(os.tmpdir(), "glass-package-certification-"));
const swiftScratch = path.join(scratch, "swiftpm");
const gates = [];

function run(name, commandName, commandArgs, { environment = {}, expectedTest = null } = {}) {
  const started = Date.now();
  const result = spawnSync(commandName, commandArgs, {
    cwd: repositoryRoot, encoding: "utf8", maxBuffer: 128 * 1024 * 1024,
    env: {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: path.join(scratch, "module-cache"),
      SWIFT_MODULECACHE_PATH: path.join(scratch, "module-cache"),
      ...environment,
    },
  });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  const executedExpectedTest = expectedTest === null || output.split("\n").some((line) =>
    line.includes(expectedTest) && line.includes("passed"));
  const gate = {
    name, passed: !result.error && result.status === 0 && executedExpectedTest,
    exitStatus: result.status, expectedTest, executedExpectedTest,
    durationMilliseconds: Date.now() - started, outputSha256: sha256(Buffer.from(output)),
    outputTail: output.trim().split("\n").slice(-20),
  };
  gates.push(gate);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${name} failed:\n${gate.outputTail.join("\n")}`);
  if (!executedExpectedTest) throw new Error(`${name} did not execute and pass ${expectedTest}`);
  return result.stdout;
}

try {
  const before = assertCleanGitState();
  const full = await validateFullDirectory(golden, { expectedStatus: "accepted" });
  if (full.problems.length) throw new Error(`selected Golden failed Full admission: ${full.problems.join("; ")}`);
  gates.push({ name: "accepted Full Golden", passed: true });

  const dispositions = await readDispositions();
  const verification = await verifyArchiveSet({
    archives: [{ name: osName, directory: golden }], dispositions,
  });
  const verificationProblems = releaseVerificationProblems(verification);
  if (verificationProblems.length) {
    throw new Error(`selected Golden is not release-ready: ${verificationProblems.join("; ")}`);
  }
  gates.push({ name: "structured Golden verification", passed: true,
    tally: verification.tally, dispositionedSkips: verification.outcomes.filter(({ disposition }) => disposition).length });

  const catalogResult = await validateCatalogFile(catalog, major);
  if (catalogResult.problems.length) throw new Error(catalogResult.problems.join("; "));
  gates.push({ name: "catalog JSON contract", passed: true });

  const dump = JSON.parse(run("Swift Package resource isolation", "swift",
    ["package", "--scratch-path", swiftScratch, "dump-package"]));
  const resourceProblems = packageResourceProblems(dump);
  if (resourceProblems.length) throw new Error(resourceProblems.join("; "));

  run("generic bundled Catalog test", "swift", ["test", "--scratch-path", swiftScratch,
    "--filter", "CatalogTests/testEveryBundledCatalogIsStructurallyCertified"],
  { expectedTest: "testEveryBundledCatalogIsStructurallyCertified" });
  run("selected-major Golden-backed Tint test", "swift", ["test", "--scratch-path", swiftScratch,
    "--filter", "TintMatrixSynthesizerTests/testSelectedMajorGoldenBackedTintCertification"], {
    environment: { CERTIFY_OS_MAJOR: String(major) },
    expectedTest: "testSelectedMajorGoldenBackedTintCertification",
  });
  run("full Swift Package tests", "swift", ["test", "--scratch-path", swiftScratch]);

  const swiftVersion = run("Swift toolchain identity", "swift", ["--version"]);
  const goldenFiles = await archiveInventory(golden);
  const catalogBytes = await readFile(catalog);
  const after = assertCleanGitState();
  if (JSON.stringify(before) !== JSON.stringify(after)) {
    throw new Error("certification changed tracked source or Golden files");
  }
  gates.push({ name: "read-only tracked tree", passed: true });
  const report = {
    schemaVersion: 1, workflow: "certify-package", generatedAt: new Date().toISOString(),
    os: osName, major, golden: { path: golden, files: goldenFiles },
    catalog: { path: catalog, bytes: catalogBytes.length, sha256: sha256(catalogBytes) },
    verification: { tally: verification.tally,
      dispositionedSkips: verification.outcomes.filter(({ disposition }) => disposition).map(({ id, reason }) => ({ id, reason })) },
    packageResources: dump.targets.find(({ name }) => name === "AdjustableGlass")?.resources ?? [],
    git: after, toolchain: swiftVersion.trim(), gates,
  };
  const bytes = `${JSON.stringify(report, null, 2)}\n`;
  if (reportDestination) await writeFile(reportDestination, bytes, { flag: "wx" });
  process.stdout.write(bytes);
} finally {
  await rm(scratch, { recursive: true, force: true });
}
