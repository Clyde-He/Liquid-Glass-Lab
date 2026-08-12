import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import {
  LearningFailure, Unverifiable, goldenDirectory, loadLearningSections, makeExpect,
} from "./golden.mjs";
import { ARCHIVE_FILES, admitArchive } from "./archive.mjs";

async function checkIntegrity(name, directory) {
  const problems = [];
  let archive = null;
  try {
    archive = await admitArchive(directory);
    const expectedName = `macOS-${archive.platform.major}`;
    if (name !== expectedName) {
      problems.push(`archive name ${name} disagrees with captured OS ${expectedName}`);
    }
  } catch (error) {
    problems.push(error.message);
  }
  return {
    name,
    directory,
    archive,
    count: archive ? Object.values(ARCHIVE_FILES).filter(
      (file) => archive.platform.major >= 27 || file !== ARCHIVE_FILES.semantic
    ).length : 0,
    problems: [...new Set(problems)],
    status: problems.length ? "failed" : "passed",
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
  const loaded = new Map();
  for (const archive of archives) {
    const result = await checkIntegrity(archive.name, archive.directory);
    integrity.push(result);
    if (result.archive) loaded.set(
      archive.name,
      await loadLearningSections(archive.directory)
    );
  }

  const learnings = await loadLearnings();
  const outcomes = [];
  for (const archive of archives) {
    const sections = loaded.get(archive.name);
    for (const learning of learnings.filter(({ kind }) => kind !== "cross-version")) {
      const missing = (learning.sections ?? []).find((name) => !sections?.[name]);
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
    integrity: integrity.map(({ archive, ...result }) => ({
      ...result, platform: archive?.platform ?? {},
    })),
    outcomes, crossVersion: crossOutcomes, tally, ...dispositionState,
    ok: integrity.every(({ problems }) => problems.length === 0) && tally.failed === 0,
  };
}
