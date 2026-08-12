import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, cp, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  archiveInventory, assertArchiveInventoryUnchanged, assertCleanGitState,
  assertCleanGitStateUnchanged, assertReportStillCurrent,
  assertReviewedComparisonEvidence, BOOTSTRAP_GATE_NAMES,
  bootstrapComparisonEvidence, createSameVolumeTransaction, gitState, inventoryDigest, pathsOverlap,
  resolveBootstrapContext, resolveCanonicalAcceptedDirectory, resolveExternalOutputPath,
} from "./lib/bootstrap.mjs";
import {
  assertAcceptedBaselineUnchanged, authenticateAcceptedBaseline, copyRetainedModules,
} from "./lib/promotion-baseline.mjs";
import { importArtifactEnvelope, MAX_ARTIFACT_BYTES } from "./lib/artifact-handoff.mjs";
import { catalogDocumentProblems, packageResourceProblems } from "./lib/catalog-certification.mjs";
import { comparisonReportIsEquivalent } from "./lib/comparison-contract.mjs";
import { compareStableDynamicRuns } from "./lib/dynamic-equivalence.mjs";
import { acceptedArchivesReplacing, goldenDirectory } from "./lib/golden.mjs";
import {
  PAYLOAD_SCHEMA_VERSIONS, PROFILE_DEFINITION_VERSION, moduleAdmissionProblems,
  safeModulePath, semanticAdmissionProblems, sha256, validateFullDirectory,
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

test("release reports reject lexical and symlinked worktree paths", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-report-path-test-"));
  try {
    const worktree = path.join(root, "repo");
    await mkdir(worktree);
    await symlink(worktree, path.join(root, "repo-link"));
    await assert.rejects(
      resolveExternalOutputPath("report.json", { worktree }), /outside/
    );
    await assert.rejects(
      resolveExternalOutputPath(path.join(root, "repo-link/report.json"), { worktree }),
      /outside/
    );
    assert.equal(
      await resolveExternalOutputPath(path.join(root, "report.json"), { worktree }),
      path.join(await realpath(root), "report.json")
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("release CLI options never consume the following flag as a value", () => {
  for (const [script, argumentsList] of [
    ["bootstrap-new-major.mjs", ["--candidate", "--accept"]],
    ["certify-package.mjs", ["--os", "--report"]],
    ["capture-profile.mjs", ["full", "--app", "--output", "/private/tmp/result"]],
  ]) {
    const result = spawnSync(process.execPath, [
      path.join(goldenDirectory, "tools", script), ...argumentsList,
    ], { encoding: "utf8" });
    assert.equal(result.status, 64, `${script}: ${result.stderr}`);
    assert.match(result.stderr, /requires a value/);
  }
});

test("release git state rejects both tracked changes and untracked files", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-git-state-test-"));
  const git = (...args) => spawnSync("git", args, { cwd: root, encoding: "utf8" });
  try {
    assert.equal(git("init").status, 0);
    await writeFile(path.join(root, "tracked.txt"), "accepted\n");
    assert.equal(git("add", "tracked.txt").status, 0);
    assert.equal(git("-c", "user.name=Golden Test", "-c", "user.email=golden@example.invalid",
      "commit", "-m", "fixture").status, 0);
    const reviewedGit = assertCleanGitState(gitState(root));
    assert.equal(reviewedGit.clean, true);
    assert.equal(assertCleanGitStateUnchanged(reviewedGit, gitState(root)).clean, true);

    await mkdir(path.join(root, "Golden"));
    const transactionState = await createSameVolumeTransaction(
      path.join(root, "Golden/macOS-99"), "macOS-99", { worktree: root }
    );
    try {
      assert.equal(transactionState.transactionRoot.startsWith(`${root}${path.sep}`), false);
      await mkdir(transactionState.transaction);
      await writeFile(path.join(transactionState.transaction, "payload.json"), "{}\n");
      assert.equal(assertCleanGitState(gitState(root)).clean, true);
    } finally {
      await rm(transactionState.transactionRoot, { recursive: true, force: true });
    }

    await writeFile(path.join(root, "untracked.txt"), "must fail closed\n");
    const untracked = gitState(root);
    assert.equal(untracked.clean, false);
    assert.throws(() => assertCleanGitState(untracked), /no tracked or untracked changes/);
    assert.throws(
      () => assertCleanGitStateUnchanged(reviewedGit, untracked),
      /no tracked or untracked changes/
    );

    await rm(path.join(root, "untracked.txt"));
    await writeFile(path.join(root, "tracked.txt"), "changed\n");
    const tracked = gitState(root);
    assert.equal(tracked.clean, false);
    assert.throws(() => assertCleanGitState(tracked), /clean tree/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("same-major promotion authenticates and binds its accepted baseline", async () => {
  const root = await realpath(await mkdtemp(
    path.join(os.tmpdir(), "golden-promotion-baseline-test-")
  ));
  const repository = path.join(root, "repo");
  const canonicalRoot = path.join(repository, "Golden");
  const canonical = path.join(canonicalRoot, "macOS-27");
  const git = (...args) => spawnSync("git", args, { cwd: repository, encoding: "utf8" });
  try {
    await mkdir(canonicalRoot, { recursive: true });
    await cp(path.join(goldenDirectory, "macOS-27"), canonical, { recursive: true });
    assert.equal(git("init").status, 0);
    assert.equal(git("add", ".").status, 0);
    assert.equal(git("-c", "user.name=Golden Test", "-c", "user.email=golden@example.invalid",
      "commit", "-m", "fixture").status, 0);
    assert.equal(await resolveCanonicalAcceptedDirectory(canonical, "macOS-27", {
      canonicalRoot, base: repository,
    }), canonical);

    const noncanonical = path.join(root, "fixtures/macOS-27");
    await mkdir(noncanonical, { recursive: true });
    await assert.rejects(
      resolveCanonicalAcceptedDirectory(noncanonical, "macOS-27", {
        canonicalRoot, base: repository,
      }),
      /must be the canonical/
    );

    const symlinkTarget = path.join(root, "symlink-target");
    const symlinkCanonicalRoot = path.join(root, "symlink-canonical");
    await mkdir(symlinkTarget);
    await mkdir(symlinkCanonicalRoot);
    await symlink(symlinkTarget, path.join(symlinkCanonicalRoot, "macOS-99"));
    await assert.rejects(
      resolveCanonicalAcceptedDirectory(
        path.join(symlinkCanonicalRoot, "macOS-99"), "macOS-99", {
          canonicalRoot: symlinkCanonicalRoot, base: root,
        }
      ),
      /not a symlink/
    );

    const baseline = await authenticateAcceptedBaseline(canonical, {
      canonicalRoot, base: repository, gitRoot: repository,
    });
    assert.deepEqual(baseline.admission.problems, []);
    const retained = baseline.admission.manifest.modules.find(
      ({ id }) => id === "external.window-context"
    );
    const payloadPath = path.join(canonical, retained.file);
    const manifestPath = path.join(canonical, "manifest.json");
    const [payload, manifestBytes] = await Promise.all([
      readFile(payloadPath), readFile(manifestPath),
    ]);
    const injectedPayload = Buffer.concat([payload, Buffer.from("\n")]);
    const injectedManifest = JSON.parse(manifestBytes);
    injectedManifest.modules.find(({ id }) => id === retained.id).integrity = {
      bytes: injectedPayload.length, sha256: sha256(injectedPayload),
    };
    await writeFile(payloadPath, injectedPayload);
    await writeFile(manifestPath, `${JSON.stringify(injectedManifest, null, 2)}\n`);
    const copied = path.join(root, "copied-retained");
    await assert.rejects(
      copyRetainedModules(copied, baseline, baseline.admission.manifest.profiles.full.required),
      /copied bytes do not match the admitted baseline/
    );
    await assert.rejects(
      assertAcceptedBaselineUnchanged(baseline),
      /accepted Full baseline bytes changed/
    );
    await writeFile(payloadPath, payload);
    await writeFile(manifestPath, manifestBytes);
    await assertAcceptedBaselineUnchanged(baseline);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("artifact stdout handoff reconstructs bytes and rejects traversal", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-artifact-handoff-test-"));
  try {
    const destination = path.join(root, "artifact.json");
    const bytes = Buffer.from("{\"passed\":true}\n");
    const envelope = JSON.stringify({
      schemaVersion: 1,
      rootKind: "file",
      entries: [{ path: "artifact", bytes: bytes.length, data: bytes.toString("base64") }],
    });
    assert.deepEqual(importArtifactEnvelope(envelope, destination), {
      rootKind: "file", entryCount: 1,
    });
    assert.deepEqual(await readFile(destination), bytes);

    const largeBytes = Buffer.alloc(9 * 1024 * 1024, 0xab);
    const directory = path.join(root, "directory");
    const directoryEnvelope = JSON.stringify({
      schemaVersion: 1,
      rootKind: "directory",
      entries: [{
        path: "unified/static-tree.json",
        bytes: largeBytes.length,
        data: largeBytes.toString("base64"),
      }],
    });
    assert.deepEqual(importArtifactEnvelope(directoryEnvelope, directory), {
      rootKind: "directory", entryCount: 1,
    });
    assert.equal((await stat(path.join(directory, "unified/static-tree.json"))).size,
      largeBytes.length);

    const traversal = JSON.stringify({
      schemaVersion: 1,
      rootKind: "directory",
      entries: [{ path: "../escape", bytes: 0, data: "" }],
    });
    assert.throws(() => importArtifactEnvelope(traversal, path.join(root, "directory")),
      /invalid artifact handoff entry/);

    const oversized = JSON.stringify({
      schemaVersion: 1,
      rootKind: "file",
      entries: [{ path: "artifact", bytes: MAX_ARTIFACT_BYTES + 1, data: "" }],
    });
    assert.throws(() => importArtifactEnvelope(oversized, destination),
      /exceeds|invalid artifact handoff entry/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("failed non-checkpoint drivers cannot replace a destination", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-failed-driver-test-"));
  try {
    const app = path.join(root, "fake-app.mjs");
    await writeFile(app, `#!/usr/bin/env node
const bytes = Buffer.from('{"passed":true}\\n');
process.stdout.write(JSON.stringify({ schemaVersion: 1, rootKind: 'file', entries: [
  { path: 'artifact', bytes: bytes.length, data: bytes.toString('base64') },
]}));
process.exit(1);
`);
    await chmod(app, 0o755);
    const output = path.join(root, "diagnostic");
    const result = spawnSync(process.execPath, [
      path.join(goldenDirectory, "tools/capture-profile.mjs"),
      "drift-scan", "--app", app, "--output", output,
    ], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    const failedDestination = `${output}.drift-staging-${result.pid}/style-atlas.json`;
    await assert.rejects(stat(failedDestination), /ENOENT/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("Dynamic equivalence ignores animation timing but detects stable endpoint drift", () => {
  const run = {
    slice: "core", usage: "Regular", cell: { direction: "insertion" },
    maximumAttachedAnimationDuration: 0.1,
    samples: [
      { phase: "preflight", elapsed: 0, value: 0 },
      { phase: "sample", elapsed: 0.5, progress: 0.4,
        filters: [{ inputs: { inputMaxHeadroom: "100", value: 4 } }] },
      { phase: "settled", elapsed: 1.1, progress: 1, value: 10,
        filters: [{ inputs: { inputMaxHeadroom: "999", value: 10 } }] },
    ],
  };
  const timingOnly = structuredClone(run);
  timingOnly.maximumAttachedAnimationDuration = 0.12;
  timingOnly.samples[1].elapsed = 0.8;
  timingOnly.samples[1].progress = 0.9;
  timingOnly.samples[1].filters[0].inputs.value = 9;
  timingOnly.samples[2].elapsed = 2;
  timingOnly.samples[2].filters[0].inputs.inputMaxHeadroom = "12345";
  assert.equal(compareStableDynamicRuns([run], [timingOnly]).equivalent, true);

  const drifted = structuredClone(timingOnly);
  drifted.samples[2].value = 11;
  const comparison = compareStableDynamicRuns([run], [drifted]);
  assert.equal(comparison.equivalent, false);
  assert.equal(comparison.changedRuns, 1);
  assert.equal(comparison.stableDifferenceCount, 1);
  assert.match(comparison.stableDifferences[0], /samples\[0\]\.value/);

  const insertion = structuredClone(run);
  const removal = structuredClone(run);
  removal.cell.direction = "removal";
  removal.samples[0] = {
    ...structuredClone(insertion.samples[2]), phase: "preflight", elapsed: 0,
  };
  removal.samples[2] = {
    ...structuredClone(insertion.samples[0]), phase: "settled", elapsed: 1.1,
  };
  assert.equal(compareStableDynamicRuns([insertion, removal], [insertion, removal]).equivalent, true);
  const brokenRemoval = structuredClone(removal);
  brokenRemoval.samples[0].value = 9;
  const pairing = compareStableDynamicRuns(
    [insertion, removal], [insertion, brokenRemoval]
  );
  assert.equal(pairing.equivalent, false);
  assert.match(pairing.problems.join("; "), /preflight does not match/);

  const reverseDrift = structuredClone(removal);
  reverseDrift.samples[2].value = 1;
  assert.match(compareStableDynamicRuns(
    [insertion, removal], [insertion, reverseDrift]
  ).problems.join("; "), /settled endpoint does not match/);

  const reordered = compareStableDynamicRuns(
    [insertion, removal], [removal, insertion]
  );
  assert.equal(reordered.equivalent, true);

  const unpaired = structuredClone(insertion);
  unpaired.slice = "repeat";
  const unpairedDrift = structuredClone(unpaired);
  unpairedDrift.samples[0].value = 1;
  assert.equal(compareStableDynamicRuns([unpaired], [unpairedDrift]).equivalent, false);

  const boundary = structuredClone(insertion);
  boundary.maximumAttachedAnimationDuration = 0.15;
  assert.equal(compareStableDynamicRuns([insertion], [boundary]).equivalent, true);
  boundary.maximumAttachedAnimationDuration = 0.151;
  assert.equal(compareStableDynamicRuns([insertion], [boundary]).equivalent, false);

  const arrayBaseline = structuredClone(insertion);
  arrayBaseline.samples[2].values = [];
  const arrayCandidate = structuredClone(arrayBaseline);
  arrayCandidate.samples[2].values = [1, 2, 3];
  assert.equal(
    compareStableDynamicRuns([arrayBaseline], [arrayCandidate]).stableDifferenceCount,
    3
  );
});

test("promotion consumes a schema-owned comparator verdict", () => {
  assert.equal(comparisonReportIsEquivalent({ equivalent: true }), true);
  assert.equal(comparisonReportIsEquivalent({ equivalent: false }), false);
  assert.throws(() => comparisonReportIsEquivalent({ summary: {} }), /schema-owned/);
});

test("semantic Recursive comparator owns and rejects topology-only drift", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-recursive-verdict-test-"));
  try {
    await mkdir(path.join(root, "unified"));
    await cp(path.join(goldenDirectory, "macOS-27/manifest.json"), path.join(root, "manifest.json"));
    const source = path.join(goldenDirectory, "macOS-27/unified/static-tree.json");
    const candidate = JSON.parse(await readFile(source, "utf8"));
    const layer = Object.values(candidate.rows[0].layers)[0];
    layer.hasMask = !layer.hasMask;
    candidate.rows[0].topologySignature = "a".repeat(64);
    await writeFile(path.join(root, "unified/static-tree.json"), `${JSON.stringify(candidate)}\n`);
    const compared = spawnSync(process.execPath, [
      path.join(goldenDirectory, "tools/compare.mjs"),
      path.join(goldenDirectory, "macOS-27"), root,
      "--module=core.static-tree", "--baseline-slice=core", "--candidate-slice=core",
    ], { encoding: "utf8" });
    assert.equal(compared.status, 0, compared.stderr);
    const report = JSON.parse(compared.stdout);
    assert.equal(report.summary.rawTopologyChangedRows, 1);
    assert.equal(report.equivalent, false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
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
  const relabeledPhase = structuredClone(dynamic);
  relabeledPhase.runs[0].samples[1].phase = "sample";
  assert.match(moduleAdmissionProblems("core.dynamic", relabeledPhase).join("; "), /invalid sample lifecycle/);
  const wrongProgressSchedule = structuredClone(dynamic);
  wrongProgressSchedule.runs[0].samples[2].requestedProgress = 0.2;
  assert.match(moduleAdmissionProblems("core.dynamic", wrongProgressSchedule).join("; "), /invalid requested progress/);
  const mismatchedRemoval = structuredClone(dynamic);
  const removal = mismatchedRemoval.runs.find(({ cell }) => cell.direction === "removal");
  removal.samples[0].layerLines.push("pairing regression");
  assert.match(moduleAdmissionProblems("core.dynamic", mismatchedRemoval).join("; "), /preflight does not match/);
  const wrongCardinality = structuredClone(dynamic);
  wrongCardinality.runs.find(({ slice }) => slice === "backdrop").cell.direction = "removal";
  assert.match(moduleAdmissionProblems("core.dynamic", wrongCardinality).join("; "), /backdrop:insertion runs/);

  const tree = JSON.parse(await readFile(path.join(goldenDirectory, "macOS-27/unified/static-tree.json")));
  const staleTopology = structuredClone(tree);
  const firstLayer = Object.values(staleTopology.rows[0].layers)[0];
  firstLayer.hasMask = !firstLayer.hasMask;
  assert.match(moduleAdmissionProblems("core.static-tree", staleTopology).join("; "), /topology signature disagrees/);
  const malformedTopology = structuredClone(tree);
  malformedTopology.rows[0].topologySignature = "z".repeat(64);
  assert.match(moduleAdmissionProblems("core.static-tree", malformedTopology).join("; "), /missing captured tree/);

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

test("shared Full admission enforces staged build policy while grandfathering accepted archives", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-build-policy-test-"));
  try {
    const candidate = path.join(root, "macOS-27");
    await cp(path.join(goldenDirectory, "macOS-27"), candidate, { recursive: true });
    const manifestPath = path.join(candidate, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.status = "staged";
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const invalid = await validateFullDirectory(candidate, { expectedStatus: "staged" });
    assert.match(invalid.problems.join("; "), /staged Full must use the single-build policy/);

    manifest.profiles.full.captureBuildPolicy = "single-build";
    manifest.profiles.full.builds = [manifest.platform.build];
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const missingContract = await validateFullDirectory(candidate, { expectedStatus: "staged" });
    assert.match(missingContract.problems.join("; "), /Dynamic contract v2/);

    manifest.profiles.full.dynamicContractVersion = 2;
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const mixedModules = await validateFullDirectory(candidate, { expectedStatus: "staged" });
    assert.match(mixedModules.problems.join("; "), /exactly match the direct Full module builds/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
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
  const gitRoot = await mkdtemp(path.join(os.tmpdir(), "golden-report-git-test-"));
  try {
    const git = (...args) => spawnSync("git", args, { cwd: gitRoot, encoding: "utf8" });
    assert.equal(git("init").status, 0);
    await writeFile(path.join(gitRoot, "tracked.txt"), "fixture\n");
    assert.equal(git("add", "tracked.txt").status, 0);
    assert.equal(git("-c", "user.name=Golden Test", "-c", "user.email=golden@example.invalid",
      "commit", "-m", "fixture").status, 0);
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
      git: gitState(gitRoot), comparisons: [], dynamicCoverage: null,
      verification: { schemaVersion: 1, ok: true, undispositionedSkips: [], staleDispositions: [] },
      gates: Object.fromEntries(BOOTSTRAP_GATE_NAMES.map((name) => [name, true])),
    };
    const context = { name: "macOS-99", candidate, target: report.target,
      baseline: null, waiver: "test fixture" };
    await assertReportStillCurrent(report, context, { gitRoot });
    const incompleteReport = structuredClone(report);
    delete incompleteReport.gates.structuredVerification;
    await assert.rejects(assertReportStillCurrent(incompleteReport, context, { gitRoot }), /exact successful bootstrap gate set/);
    const fakeVerification = structuredClone(report);
    fakeVerification.verification = { schemaVersion: 1, ok: true };
    await assert.rejects(assertReportStillCurrent(fakeVerification, context, { gitRoot }), /release-ready verification/);
    const missingComparisonEvidence = structuredClone(report);
    delete missingComparisonEvidence.dynamicCoverage;
    await assert.rejects(assertReportStillCurrent(missingComparisonEvidence, context, { gitRoot }), /comparisons or Dynamic coverage/);
    await writeFile(path.join(candidate, "manifest.json"), "{\"changed\":true}\n");
    await assert.rejects(assertReportStillCurrent(report, context, { gitRoot }), /transaction bytes do not match/);
  } finally {
    await rm(candidate, { recursive: true, force: true });
    await rm(gitRoot, { recursive: true, force: true });
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
  const promotionBaseline = await readFile(
    path.join(goldenDirectory, "tools/lib/promotion-baseline.mjs"), "utf8"
  );
  const certifier = await readFile(path.join(goldenDirectory, "tools/certify-package.mjs"), "utf8");
  assert.match(bootstrap, /source staging was preserved/);
  assert.match(bootstrap, /assertReviewedInventory\(transaction/);
  assert.match(bootstrap, /assertReviewedComparisonEvidence\(report, context, transaction\)/);
  assert.doesNotMatch(bootstrap, /replaceItemAt/);
  assert.match(capture, /releaseVerificationProblems\(verification\)/);
  assert.match(capture, /acceptedArchivesReplacing/);
  assert.match(capture, /includeCrossVersion: archives\.length > 1/);
  assert.match(capture, /createSameVolumeTransaction/);
  assert.match(capture, /authenticateAcceptedBaseline\(accepted\)/);
  assert.match(capture, /buildManifest\(staging, acceptedBaseline\)/);
  assert.match(capture, /assertArchiveInventoryUnchanged\(accepted, acceptedInventory/);
  assert.match(capture, /assertCleanGitStateUnchanged\(startingGit\)/);
  assert.match(promotionBaseline, /resolveCanonicalAcceptedDirectory/);
  assert.match(promotionBaseline, /validateFullDirectory\(directory, \{ expectedStatus: "accepted" \}\)/);
  assert.match(promotionBaseline, /copied bytes do not match the admitted baseline/);
  assert.doesNotMatch(capture, /writeFile\(stagedPath/);
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

test("bootstrap preview and accept complete end to end without self-dirtying", async () => {
  const root = await realpath(await mkdtemp(
    path.join(os.tmpdir(), "golden-bootstrap-e2e-test-")
  ));
  const repository = path.join(root, "repo");
  const fixtureRoot = path.join(repository, "Fixture");
  const candidate = path.join(fixtureRoot, "macOS-27.full-staging");
  const report = path.join(root, "bootstrap-review.json");
  const git = (...args) => spawnSync("git", args, { cwd: repository, encoding: "utf8" });
  try {
    await mkdir(path.join(repository, "Golden"), { recursive: true });
    await mkdir(fixtureRoot, { recursive: true });
    await cp(path.join(goldenDirectory, "tools"), path.join(repository, "Golden/tools"), {
      recursive: true,
    });
    await cp(path.join(goldenDirectory, "learnings"), path.join(repository, "Golden/learnings"), {
      recursive: true,
    });
    await cp(
      path.join(goldenDirectory, "verification-dispositions.json"),
      path.join(repository, "Golden/verification-dispositions.json")
    );
    await cp(path.join(goldenDirectory, "macOS-27"), candidate, { recursive: true });

    const manifestPath = path.join(candidate, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.status = "staged";
    manifest.platform.build = "26A5388g";
    manifest.profiles.full.captureBuildPolicy = "single-build";
    manifest.profiles.full.builds = ["26A5388g"];
    manifest.profiles.full.dynamicContractVersion = 2;
    const semanticModule = manifest.modules.find(({ id }) => id === "semantic.usage-trees");
    semanticModule.platform.build = "26A5388g";
    const semanticPath = path.join(candidate, semanticModule.file);
    const semantic = JSON.parse(await readFile(semanticPath, "utf8"));
    semantic.operatingSystem = semantic.operatingSystem.replace("26A5378n", "26A5388g");
    const semanticBytes = Buffer.from(`${JSON.stringify(semantic, null, 2)}\n`);
    await writeFile(semanticPath, semanticBytes);
    semanticModule.integrity = {
      bytes: semanticBytes.length,
      sha256: sha256(semanticBytes),
    };
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

    assert.equal(git("init").status, 0);
    assert.equal(git("add", ".").status, 0);
    assert.equal(git("-c", "user.name=Golden Test", "-c", "user.email=golden@example.invalid",
      "commit", "-m", "fixture").status, 0);

    const script = path.join(repository, "Golden/tools/bootstrap-new-major.mjs");
    const environment = {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: path.join(root, "module-cache"),
      SWIFT_MODULECACHE_PATH: path.join(root, "module-cache"),
    };
    const preview = spawnSync(process.execPath, [
      script, "--candidate", candidate, "--waive-baseline", "isolated test fixture",
      "--report", report,
    ], { cwd: repository, encoding: "utf8", env: environment, maxBuffer: 32 * 1024 * 1024 });
    assert.equal(preview.status, 0, preview.stderr);
    const acceptance = spawnSync(process.execPath, [
      script, "--candidate", candidate, "--waive-baseline", "isolated test fixture",
      "--report", report, "--accept",
    ], { cwd: repository, encoding: "utf8", env: environment, maxBuffer: 32 * 1024 * 1024 });
    assert.equal(acceptance.status, 0, acceptance.stderr);
    const accepted = JSON.parse(await readFile(
      path.join(repository, "Golden/macOS-27/manifest.json"), "utf8"
    ));
    assert.equal(accepted.status, "accepted");
    const preserved = JSON.parse(await readFile(manifestPath, "utf8"));
    assert.equal(preserved.status, "staged");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
