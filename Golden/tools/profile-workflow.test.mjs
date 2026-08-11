import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  archiveInventory, assertReportStillCurrent, assertReviewedComparisonEvidence,
  BOOTSTRAP_GATE_NAMES, bootstrapComparisonEvidence, gitState, inventoryDigest,
  pathsOverlap, resolveBootstrapContext,
} from "./lib/bootstrap.mjs";
import { catalogDocumentProblems, packageResourceProblems } from "./lib/catalog-certification.mjs";
import { acceptedArchivesReplacing, goldenDirectory } from "./lib/golden.mjs";
import {
  PAYLOAD_SCHEMA_VERSIONS, PROFILE_DEFINITION_VERSION, moduleAdmissionProblems,
  safeModulePath, semanticAdmissionProblems, validateFullDirectory,
} from "./lib/profile.mjs";
import {
  applyVerificationDispositions, readDispositions, releaseVerificationProblems, verifyArchiveSet,
} from "./lib/verify-engine.mjs";

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
  try {
    const mismatched = path.join(root, "macos-99.full-staging");
    await mkdir(mismatched);
    await writeFile(path.join(mismatched, "manifest.json"), JSON.stringify({ platform: { version: "99.0" } }));
    await assert.rejects(resolveBootstrapContext({ candidatePath: mismatched }), /must be named macOS-99/);

    const collision = path.join(root, "macOS-27.full-staging");
    await mkdir(collision);
    await writeFile(path.join(collision, "manifest.json"), JSON.stringify({ platform: { version: "27.0" } }));
    await assert.rejects(resolveBootstrapContext({ candidatePath: collision }), /canonical target already exists/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("shared module admission rejects coherent-looking incomplete evidence", async () => {
  const dynamic = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/unified/dynamic.json")));
  const missingAxis = structuredClone(dynamic);
  delete missingAxis.runs[0].cell.direction;
  assert.match(moduleAdmissionProblems("core.dynamic", missingAxis).join("; "), /invalid cell/);
  const wrongShortSide = structuredClone(dynamic);
  wrongShortSide.runs[0].cell.shortSide = 999;
  assert.match(moduleAdmissionProblems("core.dynamic", wrongShortSide).join("; "), /inconsistent shortSide/);
  const rejectedRun = structuredClone(dynamic);
  rejectedRun.runs[0].accepted = false;
  assert.match(moduleAdmissionProblems("core.dynamic", rejectedRun).join("; "), /not accepted/);

  const sweep = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/tint-parameterization-sweep.json")));
  const emptySweep = { ...sweep, rows: [] };
  assert.match(moduleAdmissionProblems("tint.parameterization.sweep", emptySweep).join("; "), /expected 1360 rows/);
  const duplicateSweep = structuredClone(sweep);
  duplicateSweep.rows.at(-1).colorID = duplicateSweep.rows[0].colorID;
  duplicateSweep.rows.at(-1).cell = structuredClone(duplicateSweep.rows[0].cell);
  assert.match(moduleAdmissionProblems("tint.parameterization.sweep", duplicateSweep).join("; "), /duplicate row identity/);

  const sync = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/tint-sync-resolution.json")));
  assert.match(moduleAdmissionProblems("tint.sync-resolution", { ...sync, rows: [] }).join("; "), /expected 128 rows/);
});

test("Semantic admission binds exact roles while modeling macOS 26 unavailability", async () => {
  const semantic = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/semantic-usage-trees.json")));
  assert.deepEqual(semanticAdmissionProblems(semantic, { osMajor: 27 }), []);
  const arbitrary = structuredClone(semantic);
  arbitrary.entries[0].roleTag = 99;
  arbitrary.entries[0].snapshot = {};
  assert.notDeepEqual(semanticAdmissionProblems(arbitrary, { osMajor: 27 }), []);
  const unavailable = structuredClone(semantic);
  unavailable.operatingSystem = unavailable.operatingSystem.replace("Version 27.0", "Version 26.0");
  unavailable.entries[0].isAvailable = false;
  unavailable.entries[0].snapshot = null;
  assert.deepEqual(semanticAdmissionProblems(unavailable, { osMajor: 26 }), []);
  assert.notDeepEqual(semanticAdmissionProblems(unavailable, { osMajor: 27 }), []);

  const manifest = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/manifest.json")));
  const module = manifest.modules.find(({ id }) => id === "semantic.usage-trees");
  const metadataProblems = moduleAdmissionProblems("semantic.usage-trees", unavailable, {
    osMajor: 27, expectedPlatform: module.platform,
    expectedSchemaVersion: PAYLOAD_SCHEMA_VERSIONS["semantic.usage-trees"],
  });
  assert.match(metadataProblems.join("; "), /embedded operating system disagrees/);
  assert.match(moduleAdmissionProblems("semantic.usage-trees", {
    ...semantic, formatVersion: 1, schemaVersion: 1,
  }, {
    osMajor: 27, expectedPlatform: module.platform,
    expectedSchemaVersion: PAYLOAD_SCHEMA_VERSIONS["semantic.usage-trees"],
  }).join("; "), /payload schema must be 2/);
});

test("same-major verification substitutes staging into the complete accepted archive set", async () => {
  const staging = "/private/tmp/macOS-27.full-staging";
  const archives = await acceptedArchivesReplacing({ name: "macOS-27", directory: staging });
  assert.deepEqual(archives.map(({ name }) => name), ["macOS-26", "macOS-27"]);
  assert.equal(archives.find(({ name }) => name === "macOS-27").directory, staging);
});

test("archive inventory rejects symlinks and special indirection", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-inventory-test-"));
  try {
    await writeFile(path.join(root, "file.json"), "{}\n");
    await symlink(path.join(root, "file.json"), path.join(root, "link.json"));
    await assert.rejects(archiveInventory(root), /symlinks are forbidden/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("acceptance report detects candidate byte TOCTOU", async () => {
  const candidate = await mkdtemp(path.join(os.tmpdir(), "golden-report-test-"));
  try {
    await writeFile(path.join(candidate, "manifest.json"), "{}\n");
    const files = await archiveInventory(candidate);
    const report = {
      schemaVersion: 1, workflow: "bootstrap-new-major",
      candidate: { name: "macOS-99", path: candidate, files,
        manifestSha256: files.find(({ file }) => file === "manifest.json").sha256,
        inventorySha256: inventoryDigest(files) },
      target: path.join(goldenDirectory, "macOS-99"),
      baseline: { waived: true, reason: "test fixture" },
      profileDefinitionVersion: PROFILE_DEFINITION_VERSION,
      git: gitState(), comparisons: [], dynamicCoverage: null,
      verification: { schemaVersion: 1, ok: true, undispositionedSkips: [], staleDispositions: [] },
      gates: Object.fromEntries(BOOTSTRAP_GATE_NAMES.map((name) => [name, true])),
    };
    const context = { name: "macOS-99", candidate, target: report.target,
      baseline: null, waiver: "test fixture" };
    await assertReportStillCurrent(report, context);
    const incompleteReport = structuredClone(report);
    delete incompleteReport.gates.structuredVerification;
    await assert.rejects(assertReportStillCurrent(incompleteReport, context), /exact successful bootstrap gate set/);
    const fakeVerification = structuredClone(report);
    fakeVerification.verification = { schemaVersion: 1, ok: true };
    await assert.rejects(assertReportStillCurrent(fakeVerification, context), /release-ready verification/);
    const missingComparisonEvidence = structuredClone(report);
    delete missingComparisonEvidence.dynamicCoverage;
    await assert.rejects(assertReportStillCurrent(missingComparisonEvidence, context), /comparisons or Dynamic coverage/);
    await writeFile(path.join(candidate, "manifest.json"), "{\"changed\":true}\n");
    await assert.rejects(assertReportStillCurrent(report, context), /transaction bytes do not match/);
  } finally {
    await rm(candidate, { recursive: true, force: true });
  }
});

test("baseline review evidence binds the exact comparison set and Dynamic coverage", async () => {
  const candidate = path.join(goldenDirectory, "macOS-27");
  const baseline = path.join(goldenDirectory, "macOS-26");
  const context = {
    candidate,
    manifest: JSON.parse(await readFile(path.join(candidate, "manifest.json"), "utf8")),
    baseline: { name: "macOS-26", directory: baseline, major: 26 },
  };
  const evidence = await bootstrapComparisonEvidence(context);
  assert.equal(evidence.comparisons.length, 9);
  assert.deepEqual(evidence.dynamicCoverage, {
    baselineRuns: 104, candidateRuns: 104, sharedRuns: 104, missingRuns: 0, addedRuns: 0,
  });
  await assertReviewedComparisonEvidence(evidence, context);
  await assert.rejects(
    assertReviewedComparisonEvidence({ comparisons: [], dynamicCoverage: evidence.dynamicCoverage }, context),
    /comparisons or Dynamic coverage/
  );
});

test("structured verifier applies only exact reviewed skip dispositions", async () => {
  const report = await verifyArchiveSet({
    archives: [{ name: "macOS-26", directory: path.join(goldenDirectory, "macOS-26") }],
    dispositions: await readDispositions(),
  });
  assert.equal(report.ok, true);
  assert.equal(report.tally.skipped, 2);
  assert.equal(report.undispositionedSkips.length, 0);
  assert.equal(report.staleDispositions.length, 0);
  assert.equal(report.outcomes.filter(({ disposition }) => disposition).length, 2);
});

test("cross-version dispositions bind exact scope, learning, and reason", async () => {
  const outcomes = [
    { osDirectory: "macOS-26 ↔ macOS-27 ↔ macOS-28", id: "cross-learning", reason: "missing axis", status: "skipped" },
    { osDirectory: "macOS-27", id: "passing-learning", status: "passed" },
  ];
  const exact = {
    os: "macOS-26 ↔ macOS-27 ↔ macOS-28", learning: "cross-learning", reason: "missing axis",
    reviewedBy: "test", reviewedAt: "2026-08-11",
  };
  const relevantButStale = {
    os: "macOS-27", learning: "old-learning", reason: "old reason",
    reviewedBy: "test", reviewedAt: "2026-08-11",
  };
  const irrelevant = {
    os: "macOS-99", learning: "future-learning", reason: "future reason",
    reviewedBy: "test", reviewedAt: "2026-08-11",
  };
  const state = applyVerificationDispositions(outcomes, [exact, relevantButStale, irrelevant]);
  assert.equal(state.undispositionedSkips.length, 0);
  assert.deepEqual(state.staleDispositions, [relevantButStale]);
  assert.equal(outcomes[0].disposition, exact);
  assert.match(releaseVerificationProblems({ ok: true, ...state }).join("; "), /1 reviewed dispositions are stale/);

  const root = await mkdtemp(path.join(os.tmpdir(), "golden-disposition-test-"));
  const file = path.join(root, "dispositions.json");
  try {
    await writeFile(file, `${JSON.stringify({ schemaVersion: 1, dispositions: [exact] })}\n`);
    assert.deepEqual(await readDispositions(file), [exact]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
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
  const capture = await readFile(path.join(goldenDirectory, "tools/capture-profile.mjs"), "utf8");
  const certifier = await readFile(path.join(goldenDirectory, "tools/certify-package.mjs"), "utf8");
  assert.match(bootstrap, /source staging was preserved/);
  assert.match(bootstrap, /assertReviewedInventory\(transaction/);
  assert.match(bootstrap, /assertReviewedComparisonEvidence\(report, context, transaction\)/);
  assert.doesNotMatch(bootstrap, /replaceItemAt/);
  assert.match(capture, /releaseVerificationProblems\(verification\)/);
  assert.match(capture, /acceptedArchivesReplacing/);
  assert.match(capture, /includeCrossVersion: archives\.length > 1/);
  assert.match(certifier, /--scratch-path/);
  assert.match(certifier, /executedExpectedTest/);

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
