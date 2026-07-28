#!/usr/bin/env node

// Verifies the whole archive: file integrity first, then every accepted
// learning re-derived from it.
//
//   node Golden/tools/verify.mjs                 # every OS directory
//   node Golden/tools/verify.mjs --os macOS-27   # one of them
//   node Golden/tools/verify.mjs --verbose       # show each assertion
//
// A learning is skipped, not failed, in exactly two situations: the OS
// directory lacks the section it needs, or the archive swept too little to
// decide the claim (the learning calls `expect.unverifiable`). Both print the
// reason. Nothing else may report green — a claim nothing checked must never
// look the same as a claim that held.

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import {
  LearningFailure, Unverifiable, goldenDirectory, loadUnified, makeExpect,
  osDirectories, readManifest, sha256,
} from "./lib/golden.mjs";
import { CELL_FIELDS } from "./lib/cell.mjs";

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const onlyOS = args.find((a) => a.startsWith("--os="))?.slice("--os=".length)
  ?? (args.includes("--os") ? args[args.indexOf("--os") + 1] : null);

const GREEN = "[32m", RED = "[31m", DIM = "[2m";
const YELLOW = "[33m", CYAN = "[36m", RESET = "[0m";
const supportsColor = process.stdout.isTTY;
const paint = (color, text) => (supportsColor ? `${color}${text}${RESET}` : text);

function buildOf(document) {
  const raw = document?.operatingSystem
    ?? document?.environment?.operatingSystem;
  if (typeof raw !== "string") return null;
  return raw.match(/Build ([A-Za-z0-9]+)/)?.[1] ?? null;
}

// MARK: - Integrity

async function checkIntegrity(osDirectory) {
  const directory = path.join(goldenDirectory, osDirectory);
  const manifest = await readManifest(osDirectory);
  const problems = [];
  const registered = new Set();

  for (const entry of manifest.fixtures ?? []) {
    registered.add(entry.file);
    let bytes;
    try {
      bytes = await readFile(path.join(directory, entry.file));
    } catch {
      problems.push(`${entry.file}: listed but missing`);
      continue;
    }
    if (!entry.sha256) {
      problems.push(`${entry.file}: no sha256 recorded`);
    } else if (sha256(bytes) !== entry.sha256) {
      problems.push(`${entry.file}: sha256 mismatch`);
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
      problems.push(
        `${entry.file}: contains build ${actual} but is filed under ${declared}`
      );
    }
  }

  for (const name of await readdir(directory)) {
    if (!name.endsWith(".json") || name === "manifest.json") continue;
    if (!registered.has(name)) problems.push(`${name}: on disk but unregistered`);
  }

  // The unified sections carry their own checksums in unified/meta.json rather
  // than the manifest, because they are transcoded output and are regenerated
  // as a set whenever a source fixture changes.
  const unifiedDirectory = path.join(directory, "unified");
  let unifiedCount = 0;
  try {
    const meta = JSON.parse(
      await readFile(path.join(unifiedDirectory, "meta.json"), "utf8")
    );

    // The learnings read the unified sections, not the source fixtures, so the
    // build that matters for every reported result is this one. It is declared
    // separately from `platform` because a direct capture legitimately comes
    // from a newer build than the per-study fixtures filed beside it — macOS 27
    // holds 26A5378n source fixtures under a 26A5388g unified capture. Without
    // this check a unified archive dropped in from the wrong build verifies
    // fully green, since the section checksums only prove the files match their
    // own meta entry.
    const unifiedBuild = buildOf(meta);
    const declaredUnified = manifest.unifiedPlatform?.build ?? null;
    if (declaredUnified === null) {
      problems.push(
        "manifest.json: no unifiedPlatform.build — declare the build the "
        + "unified sections must carry"
      );
    } else if (unifiedBuild === null) {
      problems.push(
        "unified/meta.json: no parseable operatingSystem build — recapture"
      );
    } else if (unifiedBuild !== declaredUnified) {
      problems.push(
        `unified/meta.json: captured on build ${unifiedBuild} but the manifest `
        + `declares ${declaredUnified} — recapture or correct the manifest`
      );
    }

    for (const [name, entry] of Object.entries(meta.sections ?? {})) {
      unifiedCount += 1;
      try {
        const bytes = await readFile(path.join(unifiedDirectory, entry.file));
        if (sha256(bytes) !== entry.sha256) {
          problems.push(`unified/${entry.file}: sha256 mismatch — rerun unify.mjs`);
        }
        // Checksums prove the file matches its meta entry, and both are written
        // in the same pass — so they cannot detect an archive that is simply
        // older than the code that produced it. A cell missing a field the
        // schema now defines is exactly that drift, and it is silent: the
        // missing field reads as null, which the archive treats as a legitimate
        // uncontrolled axis rather than a stale row.
        const document = JSON.parse(bytes.toString("utf8"));
        const cell = (document.rows ?? document.runs ?? [])[0]?.cell;
        if (cell) {
          const absent = CELL_FIELDS.filter((field) => !(field in cell));
          if (absent.length > 0) {
            problems.push(
              `unified/${entry.file}: cells predate the current schema, `
              + `missing ${absent.join(", ")} — recapture or rerun unify.mjs`
            );
          }
        }
      } catch {
        problems.push(`unified/${entry.file}: listed in meta but missing`);
      }
      if (entry.rows === 0) problems.push(`unified/${name}: no rows`);
    }
  } catch {
    problems.push("unified/meta.json: missing — run unify.mjs");
  }

  return {
    manifest,
    problems,
    count: (manifest.fixtures ?? []).length,
    unifiedCount,
  };
}

// MARK: - Learnings

async function loadLearnings() {
  const directory = path.join(goldenDirectory, "learnings");
  const files = (await readdir(directory))
    .filter((name) => name.endsWith(".mjs"))
    .sort();
  const learnings = [];
  for (const file of files) {
    const module = await import(path.join(directory, file));
    for (const learning of module.default ?? []) {
      learnings.push({ kind: "per-version", ...learning, file });
    }
  }
  return learnings;
}

const tally = { passed: 0, failed: 0, skipped: 0 };

/** Runs one learning body, printing a single outcome line plus observations. */
async function run(learning, body) {
  const observations = [];
  try {
    await body(makeExpect(observations));
    tally.passed += 1;
    console.log(`    ${paint(GREEN, "✓")} ${learning.id}`);
  } catch (error) {
    if (error instanceof Unverifiable) {
      tally.skipped += 1;
      console.log(
        `    ${paint(YELLOW, "–")} ${learning.id} `
        + `${paint(DIM, `unverifiable: ${error.message}`)}`
      );
      return;
    }
    tally.failed += 1;
    console.log(`    ${paint(RED, "✗")} ${learning.id}`);
    console.log(`        ${paint(DIM, learning.claim)}`);
    console.log(`        ${paint(RED, error.message)}`);
    if (!(error instanceof LearningFailure) && error.stack) {
      console.log(paint(DIM, `        ${error.stack.split("\n")[1]?.trim()}`));
    }
  }
  if (verbose) {
    for (const observation of observations) {
      console.log(`        ${paint(DIM, observation)}`);
    }
  }
}

// MARK: - Run

const targets = onlyOS ? [onlyOS] : await osDirectories();
const learnings = await loadLearnings();

console.log(paint(DIM, `Golden archive — ${goldenDirectory}`));
console.log(`\n${paint(DIM, "Integrity")}`);

let integrityFailed = false;
const manifests = new Map();
for (const osDirectory of targets) {
  const { manifest, problems, count, unifiedCount } =
    await checkIntegrity(osDirectory);
  manifests.set(osDirectory, manifest);
  if (problems.length === 0) {
    console.log(
      `  ${paint(GREEN, "ok")}   ${osDirectory}  ${count} fixtures, `
      + `${unifiedCount} unified sections`
    );
  } else {
    integrityFailed = true;
    console.log(`  ${paint(RED, "fail")} ${osDirectory}`);
    for (const problem of problems) console.log(`         ${problem}`);
  }
}

const archives = new Map();
for (const osDirectory of targets) {
  archives.set(osDirectory, await loadUnified(osDirectory));
}

console.log(`\n${paint(DIM, "Learnings")}`);

for (const osDirectory of targets) {
  const manifest = manifests.get(osDirectory);
  // Label the results with the build the learnings actually read. They run on
  // the unified sections, which can come from a newer build than the source
  // fixtures `platform` describes.
  const platform = manifest.unifiedPlatform ?? manifest.platform ?? {};
  console.log(
    `\n  ${osDirectory} `
    + paint(DIM, `(${platform.version ?? "?"} / ${platform.build ?? "?"} unified)`)
  );
  const sections = archives.get(osDirectory);

  for (const learning of learnings) {
    if (learning.kind === "cross-version") continue;
    const missing = (learning.sections ?? []).find((name) => !sections[name]);
    if (missing) {
      tally.skipped += 1;
      console.log(
        `    ${paint(YELLOW, "–")} ${learning.id} ${paint(DIM, `no ${missing}`)}`
      );
      continue;
    }
    await run(learning, (expect) =>
      learning.verify({ sections, expect, osDirectory })
    );
  }
}

const crossVersion = learnings.filter((l) => l.kind === "cross-version");
if (crossVersion.length > 0) {
  console.log(
    `\n  ${paint(CYAN, "cross-version")} ${paint(DIM, targets.join(" ↔ "))}`
  );
  for (const learning of crossVersion) {
    if (targets.length < 2) {
      tally.skipped += 1;
      console.log(
        `    ${paint(YELLOW, "–")} ${learning.id} `
        + paint(DIM, "needs two OS directories")
      );
      continue;
    }
    await run(learning, (expect) => learning.verify({ archives, expect }));
  }
}

console.log(
  `\n${tally.passed} passed, ${tally.failed} failed, ${tally.skipped} skipped`
  + (tally.skipped
    ? paint(DIM, "  (skipped = section not captured, or axis never swept)")
    : "")
);
if (tally.failed > 0 || integrityFailed) process.exitCode = 1;
