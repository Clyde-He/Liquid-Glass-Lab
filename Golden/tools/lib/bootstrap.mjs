import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { lstat, readFile, readdir, realpath } from "node:fs/promises";
import path from "node:path";
import { goldenDirectory } from "./golden.mjs";
import { PROFILE_DEFINITION_VERSION, sha256, validateFullDirectory } from "./profile.mjs";
import { readDispositions, verifyArchiveSet } from "./verify-engine.mjs";

export const repositoryRoot = path.dirname(goldenDirectory);

function command(commandName, args) {
  const result = spawnSync(commandName, args, {
    cwd: repositoryRoot, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
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

export async function archiveInventory(root) {
  const files = [];
  async function scan(relative = "") {
    const entries = await readdir(path.join(root, relative), { withFileTypes: true });
    entries.sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));
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

export function inventoryDigest(files) {
  return createHash("sha256").update(JSON.stringify(files)).digest("hex");
}

export function gitState() {
  const revision = command("git", ["rev-parse", "HEAD"]);
  const trackedDiff = command("git", ["diff", "--binary", "HEAD", "--"]);
  return { revision, trackedDiffSha256: sha256(Buffer.from(trackedDiff)) };
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

function directCaptureProblems(manifest, major) {
  const problems = [];
  if (manifest.status !== "staged") problems.push("candidate manifest.status must be staged");
  if (manifest.platform?.product !== "macOS"
      || Number.parseInt(manifest.platform?.version, 10) !== major) {
    problems.push(`candidate platform must be macOS major ${major}`);
  }
  const required = new Set(manifest.profiles?.full?.required ?? []);
  const modules = (manifest.modules ?? []).filter(({ id }) => required.has(id));
  const builds = new Set();
  for (const module of modules) {
    if (module.platform?.product !== "macOS"
        || Number.parseInt(module.platform?.version, 10) !== major) {
      problems.push(`${module.id}: platform does not match macOS-${major}`);
    }
    if (module.platform?.architecture !== manifest.platform?.architecture) {
      problems.push(`${module.id}: architecture disagrees with manifest`);
    }
    builds.add(module.platform?.build);
    if (module.provenance?.kind !== "direct-capture") {
      problems.push(`${module.id}: Full modules must be direct captures`);
    }
  }
  if (builds.size !== 1 || builds.has(undefined) || builds.has("unknown")) {
    problems.push(`Full modules must carry one concrete build; got ${[...builds].join(", ")}`);
  } else {
    const [build] = builds;
    if (build !== manifest.platform?.build) problems.push("manifest build disagrees with Full modules");
    if (manifest.profiles?.full?.captureBuildPolicy !== "single-build"
        || JSON.stringify(manifest.profiles?.full?.builds) !== JSON.stringify([build])) {
      problems.push("Full profile must declare its one captured build");
    }
  }
  return problems;
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
  const problems = [...full.problems, ...directCaptureProblems(manifest, major)];
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

function compareModule(baseline, candidate, module, extra = []) {
  const output = command("node", [path.join(goldenDirectory, "tools/compare.mjs"),
    baseline, candidate, `--module=${module}`, "--limit=20", ...extra]);
  return JSON.parse(output);
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

export async function buildBootstrapReport(context) {
  const dispositions = await readDispositions();
  const archives = context.baseline
    ? [context.baseline, { name: context.name, directory: context.candidate }]
    : [{ name: context.name, directory: context.candidate }];
  const verification = await verifyArchiveSet({
    archives, includeCrossVersion: Boolean(context.baseline), dispositions,
  });
  if (!verification.ok || verification.undispositionedSkips.length) {
    throw new Error("candidate verification failed or introduced undispositioned skips");
  }
  const inventory = await archiveInventory(context.candidate);
  const baselineInventory = context.baseline
    ? await archiveInventory(context.baseline.directory) : null;
  const comparisons = [];
  let dynamic = null;
  if (context.baseline) {
    const candidateResult = await validateFullDirectory(context.candidate);
    const baselineResult = await validateFullDirectory(context.baseline.directory);
    const common = context.manifest.profiles.full.required.filter((id) =>
      id !== "core.dynamic" && baselineResult.documents.has(id));
    for (const module of common) {
      if (module === "core.static-tree") {
        for (const slice of ["core", "repeat", "appearance"]) {
          comparisons.push({ module, slice, result: compareModule(
            context.baseline.directory, context.candidate, module,
            [`--baseline-slice=${slice}`, `--candidate-slice=${slice}`]
          ) });
        }
      } else {
        comparisons.push({ module, result: compareModule(
          context.baseline.directory, context.candidate, module
        ) });
      }
    }
    dynamic = dynamicCoverage(baselineResult.documents, candidateResult.documents);
  }
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
    git: gitState(), verification, comparisons, dynamicCoverage: dynamic,
    gates: {
      fullAdmission: true, exactProfile: true, directCapture: true,
      structuredVerification: true, noUndispositionedSkips: true,
      canonicalTargetAbsent: true,
    },
  };
}

export async function assertReportStillCurrent(report, context) {
  if (report.schemaVersion !== 1 || report.workflow !== "bootstrap-new-major") {
    throw new Error("review report is not a bootstrap-new-major v1 report");
  }
  if (report.candidate?.name !== context.name || report.candidate?.path !== context.candidate
      || report.target !== context.target || report.profileDefinitionVersion !== PROFILE_DEFINITION_VERSION) {
    throw new Error("review report does not describe this candidate and target");
  }
  if (Object.values(report.gates ?? {}).some((value) => value !== true)) {
    throw new Error("review report contains a failed gate");
  }
  const inventory = await archiveInventory(context.candidate);
  if (inventoryDigest(inventory) !== report.candidate.inventorySha256
      || JSON.stringify(inventory) !== JSON.stringify(report.candidate.files)) {
    throw new Error("candidate bytes changed after review");
  }
  if (context.baseline) {
    if (report.baseline?.name !== context.baseline.name
        || report.baseline?.path !== context.baseline.directory) {
      throw new Error("review report baseline does not match the selected baseline");
    }
    const baselineInventory = await archiveInventory(context.baseline.directory);
    if (inventoryDigest(baselineInventory) !== report.baseline.inventorySha256) {
      throw new Error("baseline bytes changed after review");
    }
  } else if (!report.baseline?.waived || report.baseline.reason !== context.waiver) {
    throw new Error("review report baseline waiver does not match");
  }
  if (JSON.stringify(gitState()) !== JSON.stringify(report.git)) {
    throw new Error("Golden tooling or git revision changed after review");
  }
}
