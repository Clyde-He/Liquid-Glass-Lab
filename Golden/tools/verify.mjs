#!/usr/bin/env node

// Verifies the whole archive: file integrity first, then every accepted
// learning re-derived from the fixtures.
//
//   node Golden/tools/verify.mjs                 # every OS directory
//   node Golden/tools/verify.mjs --os macOS-27   # one of them
//   node Golden/tools/verify.mjs --verbose       # show each assertion
//
// A learning is skipped, not failed, when the OS directory lacks the fixture
// it needs. That is the point: bringing up a new OS means capturing fixtures
// until the skips turn into passes, and the run tells you which are left.

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import {
  LearningFailure, goldenDirectory, makeExpect, makeFixtureLoader,
  osDirectories, readManifest, sha256,
} from "./lib/golden.mjs";

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const onlyOS = args.find((a) => a.startsWith("--os="))?.slice("--os=".length)
  ?? (args.includes("--os") ? args[args.indexOf("--os") + 1] : null);

const GREEN = "[32m", RED = "[31m", DIM = "[2m";
const YELLOW = "[33m", RESET = "[0m";
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

  return { manifest, problems, count: (manifest.fixtures ?? []).length };
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
      learnings.push({ ...learning, file });
    }
  }
  return learnings;
}

// MARK: - Run

const targets = onlyOS ? [onlyOS] : await osDirectories();
const learnings = await loadLearnings();

console.log(paint(DIM, `Golden archive — ${goldenDirectory}`));
console.log(`\n${paint(DIM, "Integrity")}`);

let integrityFailed = false;
const manifests = new Map();
for (const osDirectory of targets) {
  const { manifest, problems, count } = await checkIntegrity(osDirectory);
  manifests.set(osDirectory, manifest);
  if (problems.length === 0) {
    console.log(`  ${paint(GREEN, "ok")}   ${osDirectory}  ${count} fixtures`);
  } else {
    integrityFailed = true;
    console.log(`  ${paint(RED, "fail")} ${osDirectory}`);
    for (const problem of problems) console.log(`         ${problem}`);
  }
}

console.log(`\n${paint(DIM, "Learnings")}`);
let passed = 0, failed = 0, skipped = 0;

for (const osDirectory of targets) {
  const manifest = manifests.get(osDirectory);
  const platform = manifest.platform ?? {};
  console.log(
    `\n  ${osDirectory} ${paint(DIM, `(${platform.version ?? "?"} / ${platform.build ?? "?"})`)}`
  );
  const fixture = makeFixtureLoader(osDirectory, manifest);

  for (const learning of learnings) {
    const loaded = {};
    let missing = null;
    for (const id of learning.fixtures ?? []) {
      const document = await fixture(id);
      if (document === null) { missing = id; break; }
      loaded[id] = document;
    }
    if (missing) {
      skipped += 1;
      console.log(
        `    ${paint(YELLOW, "–")} ${learning.id} ${paint(DIM, `no ${missing}`)}`
      );
      continue;
    }

    const observations = [];
    try {
      await learning.verify({
        fixtures: loaded,
        expect: makeExpect(observations),
      });
      passed += 1;
      console.log(`    ${paint(GREEN, "✓")} ${learning.id}`);
    } catch (error) {
      failed += 1;
      const isAssertion = error instanceof LearningFailure;
      console.log(`    ${paint(RED, "✗")} ${learning.id}`);
      console.log(`        ${paint(DIM, learning.claim)}`);
      console.log(`        ${paint(RED, error.message)}`);
      if (!isAssertion && error.stack) {
        console.log(paint(DIM, `        ${error.stack.split("\n")[1]?.trim()}`));
      }
    }
    if (verbose) {
      for (const observation of observations) {
        console.log(`        ${paint(DIM, observation)}`);
      }
    }
  }
}

console.log(
  `\n${passed} passed, ${failed} failed, ${skipped} skipped`
  + `${skipped ? paint(DIM, "  (skipped = fixture not captured on that OS)") : ""}`
);
if (failed > 0 || integrityFailed) process.exitCode = 1;
