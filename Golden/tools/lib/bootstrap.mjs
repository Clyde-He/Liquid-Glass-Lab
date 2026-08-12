import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { lstat, mkdtemp, readFile, readdir, realpath, rm } from "node:fs/promises";
import path from "node:path";
import { goldenDirectory } from "./golden.mjs";
import { PROFILE_DEFINITION_VERSION, sha256, validateFullDirectory } from "./profile.mjs";
import {
  readDispositions, releaseVerificationProblems, verifyArchiveSet,
} from "./verify-engine.mjs";

export const repositoryRoot = path.dirname(goldenDirectory);
export const BOOTSTRAP_GATE_NAMES = [
  "fullAdmission", "exactProfile", "directCapture", "structuredVerification",
  "noUndispositionedSkips", "noStaleDispositions", "canonicalTargetAbsent",
];

function command(commandName, args, cwd = repositoryRoot) {
  const result = spawnSync(commandName, args, {
    cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${commandName} ${args.join(" ")} failed: ${(result.stderr || result.stdout).trim()}`);
  }
  return result.stdout.trim();
}

export function pathsOverlap(lhs, rhs) {
  const left = path.resolve(lhs);
  const right = path.resolve(rhs);
  return left === right || left.startsWith(`${right}${path.sep}`) || right.startsWith(`${left}${path.sep}`);
}

export async function resolveExternalOutputPath(input, { worktree = repositoryRoot } = {}) {
  const lexical = path.resolve(worktree, input);
  const [parent, resolvedWorktree] = await Promise.all([
    realpath(path.dirname(lexical)), realpath(worktree),
  ]);
  const destination = path.join(parent, path.basename(lexical));
  if (destination === resolvedWorktree
      || destination.startsWith(`${resolvedWorktree}${path.sep}`)) {
    throw new Error("report must resolve outside the repository worktree");
  }
  return destination;
}

export async function resolveCanonicalAcceptedDirectory(input, name, {
  canonicalRoot = goldenDirectory,
  base = repositoryRoot,
} = {}) {
  const candidate = path.resolve(base, input);
  const expected = path.resolve(canonicalRoot, name);
  if (candidate !== expected) {
    throw new Error(`--accepted must be the canonical Golden/${name} directory`);
  }
  const info = await lstat(candidate);
  if (info.isSymbolicLink() || !info.isDirectory()) {
    throw new Error("--accepted must be a real canonical directory, not a symlink");
  }
  const [resolvedCandidate, resolvedRoot] = await Promise.all([
    realpath(candidate), realpath(canonicalRoot),
  ]);
  if (resolvedCandidate !== candidate
      || resolvedCandidate !== path.join(resolvedRoot, name)) {
    throw new Error("--accepted path must not traverse symlinked ancestors");
  }
  return resolvedCandidate;
}

export async function createSameVolumeTransaction(target, label, {
  worktree = repositoryRoot,
} = {}) {
  const safeLabel = String(label).replaceAll(/[^A-Za-z0-9._-]/g, "-");
  const transactionRoot = await mkdtemp(path.join(
    path.dirname(worktree), `.${path.basename(worktree)}-${safeLabel}.transaction-`
  ));
  try {
    const [transactionInfo, targetParentInfo] = await Promise.all([
      lstat(transactionRoot), lstat(path.dirname(target)),
    ]);
    if (transactionInfo.dev !== targetParentInfo.dev) {
      throw new Error("transaction scratch and Golden target are not on the same filesystem");
    }
    return { transactionRoot, transaction: path.join(transactionRoot, label) };
  } catch (error) {
    await rm(transactionRoot, { recursive: true, force: true });
    throw error;
  }
}

export async function archiveInventory(root) {
  const files = [];
  async function scan(relative = "") {
    const entries = await readdir(path.join(root, relative), { withFileTypes: true });
    entries.sort((lhs, rhs) => lhs.name < rhs.name ? -1 : lhs.name > rhs.name ? 1 : 0);
    for (const entry of entries) {
      const file = path.posix.join(relative, entry.name);
      const info = await lstat(path.join(root, file));
      if (info.isSymbolicLink()) throw new Error(`${file}: symlinks are forbidden`);
      if (info.isDirectory()) await scan(file);
      else if (!info.isFile()) throw new Error(`${file}: special files are forbidden`);
      else {
        const bytes = await readFile(path.join(root, file));
        files.push({ file, bytes: bytes.length, sha256: sha256(bytes) });
      }
    }
  }
  await scan();
  return files;
}

export async function assertArchiveInventoryUnchanged(root, reviewed, label = "archive") {
  const current = await archiveInventory(root);
  if (JSON.stringify(current) !== JSON.stringify(reviewed)) {
    throw new Error(`${label} bytes changed after admission`);
  }
  return current;
}

export function inventoryDigest(files) {
  return createHash("sha256").update(JSON.stringify(files)).digest("hex");
}

export async function assertReviewedInventory(root, reviewed) {
  const inventory = await archiveInventory(root);
  if (inventoryDigest(inventory) !== reviewed.inventorySha256
      || JSON.stringify(inventory) !== JSON.stringify(reviewed.files)) {
    throw new Error("copied transaction bytes do not match the reviewed candidate");
  }
  const manifestSha256 = inventory.find(({ file }) => file === "manifest.json")?.sha256;
  if (!reviewed.manifestSha256 || manifestSha256 !== reviewed.manifestSha256) {
    throw new Error("reviewed candidate manifest hash is missing or inconsistent");
  }
  return inventory;
}

export async function assertReviewedPayloadInventory(root, reviewed) {
  const payloads = (await archiveInventory(root)).filter(({ file }) => file !== "manifest.json");
  const reviewedPayloads = reviewed.files.filter(({ file }) => file !== "manifest.json");
  if (JSON.stringify(payloads) !== JSON.stringify(reviewedPayloads)) {
    throw new Error("transaction payload bytes changed after review");
  }
}

export function gitState(root = repositoryRoot) {
  const revision = command("git", ["rev-parse", "HEAD"], root);
  const trackedDiff = command("git", ["diff", "--binary", "HEAD", "--"], root);
  const worktreeStatus = command(
    "git", ["status", "--porcelain=v1", "--untracked-files=all"], root
  );
  return {
    revision,
    clean: worktreeStatus.length === 0,
    trackedDiffSha256: sha256(Buffer.from(trackedDiff)),
    worktreeStatusSha256: sha256(Buffer.from(worktreeStatus)),
  };
}

export function assertCleanGitState(state = gitState()) {
  if (!state.clean) {
    throw new Error("release workflow requires a clean tree with no tracked or untracked changes");
  }
  return state;
}

export function assertCleanGitStateUnchanged(reviewed, current = gitState()) {
  const checked = assertCleanGitState(current);
  if (JSON.stringify(checked) !== JSON.stringify(reviewed)) {
    throw new Error("release Git revision or clean worktree state changed during validation");
  }
  return checked;
}

async function acceptedDirectories() {
  const entries = await readdir(goldenDirectory, { withFileTypes: true });
  const accepted = [];
  for (const entry of entries) {
    const match = /^macOS-([0-9]+)$/.exec(entry.name);
    if (!entry.isDirectory() || !match) continue;
    try {
      const manifest = JSON.parse(await readFile(path.join(goldenDirectory, entry.name, "manifest.json"), "utf8"));
      if (manifest.status === "accepted") accepted.push({ name: entry.name, major: Number(match[1]) });
    } catch {}
  }
  return accepted.sort((lhs, rhs) => lhs.major - rhs.major);
}

export async function resolveBootstrapContext({ candidatePath, baselinePath = null, waiver = null }) {
  const input = path.resolve(repositoryRoot, candidatePath);
  const inputInfo = await lstat(input);
  if (inputInfo.isSymbolicLink() || !inputInfo.isDirectory()) {
    throw new Error("candidate must be a real directory, not a symlink");
  }
  const candidate = await realpath(input);
  if (candidate !== input) throw new Error("candidate path must not traverse symlinked ancestors");
  const manifest = JSON.parse(await readFile(path.join(candidate, "manifest.json"), "utf8"));
  const major = Number.parseInt(manifest.platform?.version, 10);
  if (!Number.isInteger(major)) throw new Error("candidate manifest has no macOS major");
  const name = `macOS-${major}`;
  if (![name, `${name}.full-staging`].includes(path.basename(candidate))) {
    throw new Error(`candidate directory must be named ${name} or ${name}.full-staging`);
  }
  const target = path.join(goldenDirectory, name);
  if (pathsOverlap(candidate, target) || pathsOverlap(candidate, goldenDirectory)) {
    throw new Error("candidate must be outside the canonical Golden directory");
  }
  try {
    await lstat(target);
    throw new Error(`canonical target already exists: ${target}`);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const full = await validateFullDirectory(candidate, { expectedStatus: "staged" });
  const problems = full.problems;
  if (problems.length) throw new Error(`candidate failed Full admission:\n${problems.join("\n")}`);

  const accepted = await acceptedDirectories();
  let baseline = null;
  if (baselinePath) {
    const resolved = await realpath(path.resolve(repositoryRoot, baselinePath));
    const baselineName = path.basename(resolved);
    const match = /^macOS-([0-9]+)$/.exec(baselineName);
    if (!match || Number(match[1]) >= major) throw new Error("baseline must be a lower macOS major");
    if (resolved !== path.join(goldenDirectory, baselineName)) {
      throw new Error("baseline must be a canonical Golden/macOS-N directory");
    }
    baseline = { name: baselineName, directory: resolved, major: Number(match[1]) };
  } else {
    const latest = accepted.filter((entry) => entry.major < major).at(-1);
    if (latest) baseline = { ...latest, directory: path.join(goldenDirectory, latest.name) };
  }
  if (!baseline && !waiver) throw new Error("no lower accepted baseline; pass --waive-baseline with a reason");
  if (baseline && waiver) throw new Error("--waive-baseline cannot be combined with a baseline");
  if (baseline && pathsOverlap(candidate, baseline.directory)) throw new Error("candidate overlaps baseline");
  if (baseline) {
    const checked = await validateFullDirectory(baseline.directory, { expectedStatus: "accepted" });
    if (checked.problems.length) throw new Error(`baseline failed Full admission: ${checked.problems.join("; ")}`);
  }
  return { candidate, manifest, major, name, target, baseline, waiver };
}

function compareModule(baseline, candidate, module, extra = [], logicalCandidate = candidate) {
  const output = command("node", [path.join(goldenDirectory, "tools/compare.mjs"),
    baseline, candidate, `--module=${module}`, "--limit=20", ...extra]);
  const report = JSON.parse(output);
  report.summary.baseline = baseline;
  report.summary.candidate = logicalCandidate;
  return report;
}

function dynamicCoverage(baselineDocuments, candidateDocuments) {
  const identity = (run) => JSON.stringify([run.slice ?? null, run.cell ?? null]);
  const before = new Set((baselineDocuments.get("core.dynamic")?.runs ?? []).map(identity));
  const after = new Set((candidateDocuments.get("core.dynamic")?.runs ?? []).map(identity));
  return {
    baselineRuns: before.size, candidateRuns: after.size,
    sharedRuns: [...before].filter((item) => after.has(item)).length,
    missingRuns: [...before].filter((item) => !after.has(item)).length,
    addedRuns: [...after].filter((item) => !before.has(item)).length,
  };
}

export async function bootstrapComparisonEvidence(context, candidateDirectory = context.candidate) {
  const comparisons = [];
  let dynamic = null;
  if (context.baseline) {
    const candidateResult = await validateFullDirectory(candidateDirectory);
    const baselineResult = await validateFullDirectory(context.baseline.directory);
    const common = context.manifest.profiles.full.required.filter((id) =>
      id !== "core.dynamic" && baselineResult.documents.has(id));
    for (const module of common) {
      if (module === "core.static-tree") {
        for (const slice of ["core", "repeat", "appearance"]) {
          comparisons.push({ module, slice, result: compareModule(
            context.baseline.directory, candidateDirectory, module,
            [`--baseline-slice=${slice}`, `--candidate-slice=${slice}`], context.candidate
          ) });
        }
      } else {
        comparisons.push({ module, result: compareModule(
          context.baseline.directory, candidateDirectory, module, [], context.candidate
        ) });
      }
    }
    dynamic = dynamicCoverage(baselineResult.documents, candidateResult.documents);
  }
  return { comparisons, dynamicCoverage: dynamic };
}

export async function assertReviewedComparisonEvidence(report, context, candidateDirectory = context.candidate) {
  const expected = await bootstrapComparisonEvidence(context, candidateDirectory);
  if (!Object.hasOwn(report, "dynamicCoverage")
      || JSON.stringify(report.comparisons) !== JSON.stringify(expected.comparisons)
      || JSON.stringify(report.dynamicCoverage ?? null) !== JSON.stringify(expected.dynamicCoverage)) {
    throw new Error("review report comparisons or Dynamic coverage do not match the candidate");
  }
}

export async function buildBootstrapReport(context) {
  const git = assertCleanGitState();
  const dispositions = await readDispositions();
  const archives = context.baseline
    ? [context.baseline, { name: context.name, directory: context.candidate }]
    : [{ name: context.name, directory: context.candidate }];
  const verification = await verifyArchiveSet({
    archives, includeCrossVersion: Boolean(context.baseline), dispositions,
  });
  const verificationProblems = releaseVerificationProblems(verification);
  if (verificationProblems.length) {
    throw new Error(`candidate verification is not release-ready: ${verificationProblems.join("; ")}`);
  }
  const inventory = await archiveInventory(context.candidate);
  const baselineInventory = context.baseline
    ? await archiveInventory(context.baseline.directory) : null;
  const evidence = await bootstrapComparisonEvidence(context);
  return {
    schemaVersion: 1, workflow: "bootstrap-new-major", generatedAt: new Date().toISOString(),
    candidate: { name: context.name, path: context.candidate,
      manifestSha256: inventory.find(({ file }) => file === "manifest.json")?.sha256,
      inventorySha256: inventoryDigest(inventory), files: inventory },
    target: context.target,
    baseline: context.baseline
      ? {
        name: context.baseline.name, path: context.baseline.directory,
        manifestSha256: baselineInventory.find(({ file }) => file === "manifest.json")?.sha256,
        inventorySha256: inventoryDigest(baselineInventory),
      }
      : { waived: true, reason: context.waiver },
    profileDefinitionVersion: PROFILE_DEFINITION_VERSION,
    git, verification, ...evidence,
    gates: {
      fullAdmission: true, exactProfile: true, directCapture: true,
      structuredVerification: true, noUndispositionedSkips: true,
      noStaleDispositions: true,
      canonicalTargetAbsent: true,
    },
  };
}

export async function assertReportStillCurrent(report, context, {
  gitRoot = repositoryRoot,
} = {}) {
  if (report.schemaVersion !== 1 || report.workflow !== "bootstrap-new-major") {
    throw new Error("review report is not a bootstrap-new-major v1 report");
  }
  if (report.candidate?.name !== context.name || report.candidate?.path !== context.candidate
      || report.target !== context.target || report.profileDefinitionVersion !== PROFILE_DEFINITION_VERSION) {
    throw new Error("review report does not describe this candidate and target");
  }
  if (JSON.stringify(Object.keys(report.gates ?? {}).sort())
      !== JSON.stringify([...BOOTSTRAP_GATE_NAMES].sort())
      || BOOTSTRAP_GATE_NAMES.some((name) => report.gates[name] !== true)) {
    throw new Error("review report does not contain the exact successful bootstrap gate set");
  }
  if (report.verification?.schemaVersion !== 1
      || releaseVerificationProblems(report.verification).length
      || !Array.isArray(report.comparisons)) {
    throw new Error("review report has no valid release-ready verification or comparisons");
  }
  if (report.git?.clean !== true) {
    throw new Error("review report was not created from a clean tree");
  }
  await assertReviewedInventory(context.candidate, report.candidate);
  await assertReviewedComparisonEvidence(report, context);
  if (context.baseline) {
    if (report.baseline?.name !== context.baseline.name
        || report.baseline?.path !== context.baseline.directory) {
      throw new Error("review report baseline does not match the selected baseline");
    }
    const baselineInventory = await archiveInventory(context.baseline.directory);
    if (inventoryDigest(baselineInventory) !== report.baseline.inventorySha256) {
      throw new Error("baseline bytes changed after review");
    }
    const baselineManifest = baselineInventory.find(({ file }) => file === "manifest.json")?.sha256;
    if (!report.baseline.manifestSha256 || baselineManifest !== report.baseline.manifestSha256) {
      throw new Error("review report baseline manifest hash is missing or inconsistent");
    }
  } else if (!report.baseline?.waived || report.baseline.reason !== context.waiver) {
    throw new Error("review report baseline waiver does not match");
  }
  if (JSON.stringify(assertCleanGitState(gitState(gitRoot))) !== JSON.stringify(report.git)) {
    throw new Error("Golden tooling or git revision changed after review");
  }
}
