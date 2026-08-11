#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { archiveInventory, gitState, repositoryRoot } from "./lib/bootstrap.mjs";
import { goldenDirectory } from "./lib/golden.mjs";
import { validateCatalogFile, packageResourceProblems } from "./lib/catalog-certification.mjs";
import { sha256, validateFullDirectory } from "./lib/profile.mjs";
import { readDispositions, verifyArchiveSet } from "./lib/verify-engine.mjs";

const args = process.argv.slice(2);
const osName = option("--os");
const reportPath = option("--report");

function option(name) {
  const joined = args.find((argument) => argument.startsWith(`${name}=`));
  if (joined) return joined.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
}

function usage(message) {
  if (message) console.error(message);
  console.error("usage: certify-package.mjs --os macOS-N [--report FILE]");
  process.exit(64);
}

const match = /^macOS-([0-9]+)$/.exec(osName ?? "");
if (!match) usage("--os must use the exact macOS-N form");
const major = Number(match[1]);
const golden = path.join(goldenDirectory, osName);
const catalog = path.join(repositoryRoot, `LiquidGlassLab/GlassMaterial/Catalog/glass-macos-${major}.json`);
const scratch = await mkdtemp(path.join(os.tmpdir(), "glass-package-certification-"));
const gates = [];

function run(name, commandName, commandArgs, environment = {}) {
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
  const gate = {
    name, passed: !result.error && result.status === 0, exitStatus: result.status,
    durationMilliseconds: Date.now() - started, outputSha256: sha256(Buffer.from(output)),
    outputTail: output.trim().split("\n").slice(-20),
  };
  gates.push(gate);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${name} failed:\n${gate.outputTail.join("\n")}`);
  return result.stdout;
}

try {
  const before = gitState();
  const full = await validateFullDirectory(golden, { expectedStatus: "accepted" });
  if (full.problems.length) throw new Error(`selected Golden failed Full admission: ${full.problems.join("; ")}`);
  gates.push({ name: "accepted Full Golden", passed: true });

  const dispositions = await readDispositions();
  const verification = await verifyArchiveSet({
    archives: [{ name: osName, directory: golden }], dispositions,
  });
  if (!verification.ok || verification.undispositionedSkips.length) {
    throw new Error("selected Golden failed verification or has undispositioned skips");
  }
  gates.push({ name: "structured Golden verification", passed: true,
    tally: verification.tally, dispositionedSkips: verification.outcomes.filter(({ disposition }) => disposition).length });

  const catalogResult = await validateCatalogFile(catalog, major);
  if (catalogResult.problems.length) throw new Error(catalogResult.problems.join("; "));
  gates.push({ name: "catalog JSON contract", passed: true });

  const dump = JSON.parse(run("Swift Package resource isolation", "swift", ["package", "dump-package"]));
  const resourceProblems = packageResourceProblems(dump);
  if (resourceProblems.length) throw new Error(resourceProblems.join("; "));

  run("generic bundled Catalog test", "swift", ["test", "--filter",
    "CatalogTests/testEveryBundledCatalogIsStructurallyCertified"]);
  run("selected-major Golden-backed Tint test", "swift", ["test", "--filter",
    "TintMatrixSynthesizerTests/testSelectedMajorGoldenBackedTintCertification"],
  { CERTIFY_OS_MAJOR: String(major) });
  run("full Swift Package tests", "swift", ["test"]);

  const after = gitState();
  if (JSON.stringify(before) !== JSON.stringify(after)) {
    throw new Error("certification changed tracked source or Golden files");
  }
  gates.push({ name: "read-only tracked tree", passed: true });
  const swiftVersion = run("Swift toolchain identity", "swift", ["--version"]);
  const goldenFiles = await archiveInventory(golden);
  const catalogBytes = await readFile(catalog);
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
  if (reportPath) await writeFile(path.resolve(repositoryRoot, reportPath), bytes, { flag: "wx" });
  process.stdout.write(bytes);
} finally {
  await rm(scratch, { recursive: true, force: true });
}
