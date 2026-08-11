import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import {
  LearningFailure, Unverifiable, goldenDirectory, loadUnifiedAt, makeExpect,
  readManifestAt, sha256,
} from "./golden.mjs";
import { CELL_FIELDS } from "./cell.mjs";
import { validateFullDirectory } from "./profile.mjs";

function buildOf(document) {
  const raw = document?.operatingSystem ?? document?.environment?.operatingSystem;
  if (typeof raw !== "string") return null;
  return raw.match(/Build ([A-Za-z0-9]+)/)?.[1] ?? null;
}

async function checkIntegrity(name, directory) {
  const manifest = await readManifestAt(directory);
  const problems = [];
  const declaredName = `macOS-${Number.parseInt(manifest.platform?.version, 10)}`;
  if (name !== declaredName) problems.push(`archive name ${name} disagrees with manifest major ${declaredName}`);
  const registered = new Set((manifest.modules ?? []).map((module) => module.file));

  for (const entry of manifest.fixtures ?? []) {
    registered.add(entry.file);
    let bytes;
    try {
      bytes = await readFile(path.join(directory, entry.file));
    } catch {
      problems.push(`${entry.file}: listed but missing`);
      continue;
    }
    if (!entry.sha256) problems.push(`${entry.file}: no sha256 recorded`);
    else if (sha256(bytes) !== entry.sha256) problems.push(`${entry.file}: sha256 mismatch`);
    const authoritativeModule = manifest.modules.find((module) => module.file === entry.file);
    if (authoritativeModule?.integrity?.bytes !== undefined
        && bytes.length !== authoritativeModule.integrity.bytes) {
      problems.push(`${entry.file}: byte count disagrees with manifest`);
    }
    let document;
    try {
      document = JSON.parse(bytes.toString("utf8"));
    } catch {
      problems.push(`${entry.file}: not valid JSON`);
      continue;
    }
    const actual = buildOf(document);
    const declared = entry.platform?.build ?? manifest.platform?.build ?? null;
    if (actual !== null && actual !== declared) {
      problems.push(`${entry.file}: contains build ${actual} but is filed under ${declared}`);
    }
  }

  registered.add("unified/meta.json");
  async function scan(relative = "") {
    for (const entry of await readdir(path.join(directory, relative), { withFileTypes: true })) {
      const file = path.posix.join(relative, entry.name);
      if (entry.isDirectory()) await scan(file);
      else if (entry.name.endsWith(".json") && file !== "manifest.json"
          && !registered.has(file)) problems.push(`${file}: on disk but unregistered`);
    }
  }
  await scan();

  let unifiedCount = 0;
  try {
    const meta = JSON.parse(await readFile(path.join(directory, "unified/meta.json"), "utf8"));
    const unifiedModules = (manifest.modules ?? []).filter(
      (module) => module.id.startsWith("core.") && module.file.startsWith("unified/")
    );
    const declaredBuilds = [...new Set(
      unifiedModules.map((module) => module.platform?.build).filter(Boolean)
    )];
    const unifiedBuild = buildOf(meta);
    const declaredUnified = declaredBuilds.length === 1 ? declaredBuilds[0] : null;
    if (declaredBuilds.length !== 1) {
      problems.push(`manifest.json: unified modules must declare one build, got ${declaredBuilds.join(", ")}`);
    } else if (unifiedBuild === null) {
      problems.push("unified/meta.json: no parseable operatingSystem build — recapture");
    } else if (unifiedBuild !== declaredUnified) {
      problems.push(
        `unified/meta.json: captured on build ${unifiedBuild} but the manifest `
        + `declares ${declaredUnified} — recapture or correct the manifest`
      );
    }

    for (const module of unifiedModules) {
      const section = module.id.slice("core.".length);
      const metaEntry = meta.sections?.[section];
      if (metaEntry?.sha256 && metaEntry.sha256 !== module.integrity?.sha256) {
        problems.push(`${module.file}: payload meta checksum disagrees with manifest`);
      }
      if (metaEntry?.bytes !== undefined && metaEntry.bytes !== module.integrity?.bytes) {
        problems.push(`${module.file}: payload meta byte count disagrees with manifest`);
      }
      if (metaEntry?.rows !== undefined && metaEntry.rows !== module.statistics?.rows) {
        problems.push(`${module.file}: payload meta row count disagrees with manifest`);
      }
      if (meta.role !== undefined && meta.role !== module.role) {
        problems.push(`${module.file}: payload meta role disagrees with manifest`);
      }
      unifiedCount += 1;
      try {
        const bytes = await readFile(path.join(directory, module.file));
        if (sha256(bytes) !== module.integrity?.sha256) {
          problems.push(`${module.file}: sha256 mismatch — recapture the registered profile`);
        }
        if (bytes.length !== module.integrity?.bytes) {
          problems.push(`${module.file}: byte count disagrees with manifest`);
        }
        const document = JSON.parse(bytes.toString("utf8"));
        const cell = (document.rows ?? document.runs ?? [])[0]?.cell;
        if (cell) {
          const absent = CELL_FIELDS.filter((field) => !(field in cell));
          if (absent.length) {
            problems.push(
              `${module.file}: cells predate the current schema, missing ${absent.join(", ")} `
              + "— recapture the registered profile"
            );
          }
        }
      } catch {
        problems.push(`${module.file}: listed in manifest but missing`);
      }
      if (module.statistics?.rows === 0) problems.push(`unified/${section}: no rows`);
    }
  } catch {
    problems.push("unified/meta.json: missing — recapture the registered profile");
  }

  const full = await validateFullDirectory(directory);
  problems.push(...full.problems);
  return {
    name, directory, manifest, count: (manifest.fixtures ?? []).length,
    unifiedCount, problems: [...new Set(problems)], status: problems.length ? "failed" : "passed",
  };
}

async function loadLearnings() {
  const directory = path.join(goldenDirectory, "learnings");
  const files = (await readdir(directory)).filter((name) => name.endsWith(".mjs")).sort();
  const learnings = [];
  for (const file of files) {
    const module = await import(path.join(directory, file));
    for (const learning of module.default ?? []) {
      learnings.push({ kind: "per-version", ...learning, file });
    }
  }
  return learnings;
}

async function runLearning(learning, body, context) {
  const observations = [];
  try {
    await body(makeExpect(observations));
    return { ...context, id: learning.id, claim: learning.claim, file: learning.file,
      status: "passed", observations };
  } catch (error) {
    if (error instanceof Unverifiable) {
      return { ...context, id: learning.id, claim: learning.claim, file: learning.file,
        status: "skipped", reason: error.message, observations };
    }
    return { ...context, id: learning.id, claim: learning.claim, file: learning.file,
      status: "failed", reason: error.message,
      unexpected: !(error instanceof LearningFailure), observations };
  }
}

export async function readDispositions(file = path.join(goldenDirectory, "verification-dispositions.json")) {
  const document = JSON.parse(await readFile(file, "utf8"));
  if (document.schemaVersion !== 1 || !Array.isArray(document.dispositions)) {
    throw new Error("verification dispositions must use schemaVersion 1");
  }
  const keys = new Set();
  for (const entry of document.dispositions) {
    const key = `${entry.os}\0${entry.learning}`;
    if (!/^macOS-[0-9]+(?: ↔ macOS-[0-9]+)*$/.test(entry.os ?? "")
        || typeof entry.learning !== "string"
        || !entry.learning || typeof entry.reason !== "string" || !entry.reason
        || typeof entry.reviewedBy !== "string" || !entry.reviewedBy
        || !/^\d{4}-\d{2}-\d{2}$/.test(entry.reviewedAt ?? "")) {
      throw new Error("verification disposition entries must carry OS, learning, reason, and review metadata");
    }
    if (keys.has(key)) throw new Error(`duplicate verification disposition: ${entry.os} ${entry.learning}`);
    keys.add(key);
  }
  return document.dispositions;
}

export function applyVerificationDispositions(outcomes, dispositions) {
  const used = new Set();
  const skipped = outcomes.filter(({ status }) => status === "skipped");
  for (const outcome of skipped) {
    const index = dispositions.findIndex((entry) => entry.os === outcome.osDirectory
      && entry.learning === outcome.id && entry.reason === outcome.reason);
    if (index >= 0) {
      outcome.disposition = dispositions[index];
      used.add(index);
    }
  }
  return {
    undispositionedSkips: skipped.filter(({ disposition }) => !disposition),
    staleDispositions: dispositions.filter((entry, index) =>
      outcomes.some(({ osDirectory }) => osDirectory === entry.os) && !used.has(index)),
  };
}

export function releaseVerificationProblems(report) {
  const problems = [];
  if (report?.ok !== true) problems.push("integrity or learning failures are present");
  if (!Array.isArray(report?.undispositionedSkips)) {
    problems.push("undispositioned skip results are missing");
  } else if (report.undispositionedSkips.length) {
    problems.push(`${report.undispositionedSkips.length} skips have no exact reviewed disposition`);
  }
  if (!Array.isArray(report?.staleDispositions)) {
    problems.push("stale disposition results are missing");
  } else if (report.staleDispositions.length) {
    problems.push(`${report.staleDispositions.length} reviewed dispositions are stale`);
  }
  return problems;
}

/**
 * Verifies named archive directories without relying on their location under Golden/.
 * Cross-version learnings run only when explicitly requested and at least two archives exist.
 */
export async function verifyArchiveSet({ archives, includeCrossVersion = false, dispositions = [] }) {
  if (!Array.isArray(archives) || archives.length === 0) throw new Error("no archives to verify");
  const names = new Set();
  for (const archive of archives) {
    if (!/^macOS-[0-9]+$/.test(archive.name)) throw new Error(`invalid archive name: ${archive.name}`);
    if (names.has(archive.name)) throw new Error(`duplicate archive name: ${archive.name}`);
    names.add(archive.name);
  }

  const integrity = [];
  const manifests = new Map();
  const loaded = new Map();
  for (const archive of archives) {
    const result = await checkIntegrity(archive.name, archive.directory);
    integrity.push(result);
    manifests.set(archive.name, result.manifest);
    loaded.set(archive.name, await loadUnifiedAt(archive.directory));
  }

  const learnings = await loadLearnings();
  const outcomes = [];
  for (const archive of archives) {
    const sections = loaded.get(archive.name);
    for (const learning of learnings.filter(({ kind }) => kind !== "cross-version")) {
      const missing = (learning.sections ?? []).find((name) => !sections[name]);
      if (missing) {
        outcomes.push({ osDirectory: archive.name, id: learning.id, claim: learning.claim,
          file: learning.file, status: "skipped", reason: `no ${missing}`, observations: [] });
      } else {
        outcomes.push(await runLearning(learning,
          (expect) => learning.verify({ sections, expect, osDirectory: archive.name }),
          { osDirectory: archive.name }));
      }
    }
  }

  const crossOutcomes = [];
  if (includeCrossVersion) {
    for (const learning of learnings.filter(({ kind }) => kind === "cross-version")) {
      if (archives.length < 2) {
        crossOutcomes.push({ osDirectory: archives.map(({ name }) => name).join(" ↔ "),
          id: learning.id, claim: learning.claim, file: learning.file, status: "skipped",
          reason: "needs two OS directories", observations: [] });
      } else {
        crossOutcomes.push(await runLearning(learning,
          (expect) => learning.verify({ archives: loaded, expect }),
          { osDirectory: archives.map(({ name }) => name).join(" ↔ ") }));
      }
    }
  }

  const allOutcomes = [...outcomes, ...crossOutcomes];
  const dispositionState = applyVerificationDispositions(allOutcomes, dispositions);
  const tally = {
    passed: allOutcomes.filter(({ status }) => status === "passed").length,
    failed: allOutcomes.filter(({ status }) => status === "failed").length,
    skipped: allOutcomes.filter(({ status }) => status === "skipped").length,
  };
  return {
    schemaVersion: 1, archives: archives.map(({ name, directory }) => ({ name, directory })),
    integrity: integrity.map(({ manifest, ...result }) => ({ ...result,
      platform: manifest.unifiedPlatform ?? manifest.platform ?? {} })),
    outcomes, crossVersion: crossOutcomes, tally, ...dispositionState,
    ok: integrity.every(({ problems }) => problems.length === 0) && tally.failed === 0,
  };
}
