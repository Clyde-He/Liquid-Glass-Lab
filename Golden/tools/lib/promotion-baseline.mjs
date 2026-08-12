import { copyFile, mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import {
  archiveInventory, assertArchiveInventoryUnchanged, assertCleanGitState,
  assertCleanGitStateUnchanged, gitState, repositoryRoot,
  resolveCanonicalAcceptedDirectory,
} from "./bootstrap.mjs";
import { goldenDirectory } from "./golden.mjs";
import { sha256, validateFullDirectory } from "./profile.mjs";

export async function authenticateAcceptedBaseline(input, {
  canonicalRoot = goldenDirectory,
  base = repositoryRoot,
  gitRoot = repositoryRoot,
} = {}) {
  const git = assertCleanGitState(gitState(gitRoot));
  const name = path.basename(path.resolve(base, input));
  if (!/^macOS-[0-9]+$/.test(name)) {
    throw new Error("--accepted must name a canonical macOS-N directory");
  }
  const directory = await resolveCanonicalAcceptedDirectory(input, name, {
    canonicalRoot, base,
  });
  const inventory = await archiveInventory(directory);
  const admission = await validateFullDirectory(directory, { expectedStatus: "accepted" });
  if (admission.problems.length) {
    throw new Error(`invalid accepted Full baseline: ${admission.problems.join("; ")}`);
  }
  const manifestName = `macOS-${Number.parseInt(admission.manifest.platform?.version, 10)}`;
  if (manifestName !== name) {
    throw new Error(`accepted Full baseline platform does not match ${name}`);
  }
  await assertArchiveInventoryUnchanged(directory, inventory, "accepted Full baseline");
  assertCleanGitStateUnchanged(git, gitState(gitRoot));
  return { name, directory, inventory, admission, git, gitRoot };
}

export async function assertAcceptedBaselineUnchanged(baseline) {
  await assertArchiveInventoryUnchanged(
    baseline.directory, baseline.inventory, "accepted Full baseline"
  );
  assertCleanGitStateUnchanged(baseline.git, gitState(baseline.gitRoot));
}

export async function copyRetainedModules(root, baseline, directModuleIDs) {
  if (!baseline) return { modules: [], carriedForward: [] };
  const direct = new Set(directModuleIDs);
  const modules = [];
  const carriedForward = [];
  for (const admittedModule of baseline.admission.manifest.modules ?? []) {
    if (direct.has(admittedModule.id)) continue;
    const reviewed = baseline.inventory.find(({ file }) => file === admittedModule.file);
    if (!reviewed) {
      throw new Error(`${admittedModule.id}: admitted source is missing from baseline inventory`);
    }
    const target = path.join(root, admittedModule.file);
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.join(baseline.directory, admittedModule.file), target);
    const bytes = await readFile(target);
    if (bytes.length !== reviewed.bytes || sha256(bytes) !== reviewed.sha256) {
      throw new Error(`${admittedModule.id}: copied bytes do not match the admitted baseline`);
    }
    modules.push(structuredClone(admittedModule));
    if (admittedModule.profileStatus === "carried-forward") {
      carriedForward.push(admittedModule.id);
    }
  }
  await assertAcceptedBaselineUnchanged(baseline);
  return { modules, carriedForward };
}
