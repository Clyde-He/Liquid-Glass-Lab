import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  archiveInventory, assertReportStillCurrent, gitState, inventoryDigest, pathsOverlap,
  resolveBootstrapContext,
} from "./lib/bootstrap.mjs";
import { catalogDocumentProblems, packageResourceProblems } from "./lib/catalog-certification.mjs";
import { goldenDirectory } from "./lib/golden.mjs";
import { PROFILE_DEFINITION_VERSION, safeModulePath, validateFullDirectory } from "./lib/profile.mjs";
import { readDispositions, verifyArchiveSet } from "./lib/verify-engine.mjs";

test("accepted archives satisfy the shared exact Full admission contract", async () => {
  for (const name of ["macOS-26", "macOS-27"]) {
    const result = await validateFullDirectory(path.join(goldenDirectory, name), { expectedStatus: "accepted" });
    assert.deepEqual(result.problems, [], `${name}: ${result.problems.join("; ")}`);
  }
});

test("module paths and bootstrap paths reject traversal and overlap", () => {
  assert.equal(safeModulePath("unified/dynamic.json"), true);
  for (const file of ["../dynamic.json", "/tmp/dynamic.json", "a//b.json", "a\\b.json"]) {
    assert.equal(safeModulePath(file), false, file);
  }
  assert.equal(pathsOverlap("/private/tmp/macOS-28", "/private/tmp/macOS-28/child"), true);
  assert.equal(pathsOverlap("/private/tmp/macOS-28", "/private/tmp/macOS-29"), false);
});

test("bootstrap rejects case-mismatched staging and an existing canonical target", async () => {
  const root = await mkdtemp("/private/tmp/golden-bootstrap-path-test-");
  const mismatched = path.join(root, "macos-99.full-staging");
  await mkdir(mismatched);
  await writeFile(path.join(mismatched, "manifest.json"), JSON.stringify({ platform: { version: "99.0" } }));
  await assert.rejects(resolveBootstrapContext({ candidatePath: mismatched }), /must be named macOS-99/);

  const collision = path.join(root, "macOS-27.full-staging");
  await mkdir(collision);
  await writeFile(path.join(collision, "manifest.json"), JSON.stringify({ platform: { version: "27.0" } }));
  await assert.rejects(resolveBootstrapContext({ candidatePath: collision }), /canonical target already exists/);
});

test("archive inventory rejects symlinks and special indirection", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-inventory-test-"));
  await writeFile(path.join(root, "file.json"), "{}\n");
  await symlink(path.join(root, "file.json"), path.join(root, "link.json"));
  await assert.rejects(archiveInventory(root), /symlinks are forbidden/);
});

test("acceptance report detects candidate byte TOCTOU", async () => {
  const candidate = await mkdtemp(path.join(os.tmpdir(), "golden-report-test-"));
  await writeFile(path.join(candidate, "manifest.json"), "{}\n");
  const files = await archiveInventory(candidate);
  const report = {
    schemaVersion: 1, workflow: "bootstrap-new-major",
    candidate: { name: "macOS-99", path: candidate, files,
      inventorySha256: inventoryDigest(files) },
    target: path.join(goldenDirectory, "macOS-99"),
    baseline: { waived: true, reason: "test fixture" },
    profileDefinitionVersion: PROFILE_DEFINITION_VERSION,
    git: gitState(), gates: { reviewed: true },
  };
  const context = { name: "macOS-99", candidate, target: report.target,
    baseline: null, waiver: "test fixture" };
  await assertReportStillCurrent(report, context);
  await writeFile(path.join(candidate, "manifest.json"), "{\"changed\":true}\n");
  await assert.rejects(assertReportStillCurrent(report, context), /candidate bytes changed/);
});

test("structured verifier applies only exact reviewed skip dispositions", async () => {
  const report = await verifyArchiveSet({
    archives: [{ name: "macOS-26", directory: path.join(goldenDirectory, "macOS-26") }],
    dispositions: await readDispositions(),
  });
  assert.equal(report.ok, true);
  assert.equal(report.tally.skipped, 2);
  assert.equal(report.undispositionedSkips.length, 0);
  assert.equal(report.outcomes.filter(({ disposition }) => disposition).length, 2);
});

test("catalog and package resource contracts are exact", async () => {
  const catalog = JSON.parse(await readFile(
    path.join(goldenDirectory, "../LiquidGlassLab/GlassMaterial/Catalog/glass-macos-27.json"), "utf8"
  ));
  assert.deepEqual(catalogDocumentProblems(catalog, 27), []);
  const invalid = structuredClone(catalog);
  invalid.tintMatrices = [{}];
  assert.match(catalogDocumentProblems(invalid, 27).join("; "), /must not bundle tintMatrices/);
  assert.deepEqual(packageResourceProblems({ targets: [{ name: "AdjustableGlass",
    resources: [{ path: "Catalog" }] }] }), []);
  assert.match(packageResourceProblems({ targets: [{ name: "AdjustableGlass",
    resources: [{ path: "Catalog" }, { path: "Golden" }] }] }).join("; "), /exactly Catalog/);
});

test("atomic new-major install uses the Darwin no-replace primitive", async () => {
  const source = await readFile(path.join(goldenDirectory, "tools/atomic-create.swift"), "utf8");
  assert.match(source, /renameatx_np/);
  assert.match(source, /RENAME_EXCL/);
  const bootstrap = await readFile(path.join(goldenDirectory, "tools/bootstrap-new-major.mjs"), "utf8");
  assert.match(bootstrap, /source staging was preserved/);
  assert.doesNotMatch(bootstrap, /replaceItemAt/);

  const root = await mkdtemp(path.join(os.tmpdir(), "golden-atomic-create-test-"));
  const first = path.join(root, "first");
  const second = path.join(root, "second");
  const target = path.join(root, "target");
  const moduleCache = path.join(root, "module-cache");
  await mkdir(first);
  await mkdir(second);
  const environment = {
    ...process.env,
    CLANG_MODULE_CACHE_PATH: moduleCache,
    SWIFT_MODULECACHE_PATH: moduleCache,
  };
  const helper = path.join(goldenDirectory, "tools/atomic-create.swift");
  const initial = spawnSync("swift", [helper, first, target], { encoding: "utf8", env: environment });
  assert.equal(initial.status, 0, initial.stderr);
  const raced = spawnSync("swift", [helper, second, target], { encoding: "utf8", env: environment });
  assert.notEqual(raced.status, 0);
  assert.match(raced.stderr, /File exists/);
  assert.equal((await stat(second)).isDirectory(), true);
  await rm(root, { recursive: true, force: true });
});
