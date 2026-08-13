#!/usr/bin/env node

import path from "node:path";
import { goldenDirectory, osDirectories } from "./lib/golden.mjs";
import {
  readDispositions, releaseVerificationProblems, verifyArchiveSet,
} from "./lib/verify-engine.mjs";

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const json = args.includes("--json");
const onlyOS = value("--os");
const candidate = value("--candidate");
const candidateName = value("--candidate-name");

function value(name) {
  const joined = args.find((argument) => argument.startsWith(`${name}=`));
  if (joined) return joined.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
}

function usage(message) {
  if (message) console.error(message);
  console.error("usage: verify.mjs [--os macOS-N] [--candidate DIR --candidate-name macOS-N] [--json] [--verbose]");
  process.exit(64);
}

if ((candidate && !candidateName) || (!candidate && candidateName) || (candidate && onlyOS)) usage();
const candidateInput = candidate ? path.resolve(candidate) : null;
const archives = candidate
  ? [{ name: candidateName, directory: candidateInput }]
  : (onlyOS ? [onlyOS] : await osDirectories()).map((name) => ({
    name, directory: path.join(goldenDirectory, name),
  }));
const dispositions = await readDispositions();
const report = await verifyArchiveSet({
  archives,
  includeCrossVersion: !candidate && (!onlyOS || archives.length > 1),
  dispositions,
});

if (json) {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} else {
  const green = (text) => process.stdout.isTTY ? `\u001b[32m${text}\u001b[0m` : text;
  const red = (text) => process.stdout.isTTY ? `\u001b[31m${text}\u001b[0m` : text;
  const yellow = (text) => process.stdout.isTTY ? `\u001b[33m${text}\u001b[0m` : text;
  console.log(`Golden archive — ${goldenDirectory}`);
  console.log("\nIntegrity");
  for (const integrity of report.integrity) {
    if (integrity.status === "passed") {
      console.log(`  ${green("ok")}   ${integrity.name}  ${integrity.count} evidence documents`);
    } else {
      console.log(`  ${red("fail")} ${integrity.name}`);
      for (const problem of integrity.problems) console.log(`         ${problem}`);
    }
  }
  console.log("\nLearnings");
  for (const archive of archives) {
    const platform = report.integrity.find(({ name }) => name === archive.name)?.platform ?? {};
    console.log(`\n  ${archive.name} (${platform.version ?? "?"} / ${platform.build ?? "?"})`);
    for (const outcome of report.outcomes.filter(({ osDirectory }) => osDirectory === archive.name)) {
      const mark = outcome.status === "passed" ? green("✓")
        : outcome.status === "failed" ? red("✗") : yellow("–");
      console.log(`    ${mark} ${outcome.id}${outcome.reason ? ` ${outcome.reason}` : ""}`);
      if (outcome.status === "failed") console.log(`        ${outcome.claim}`);
      if (verbose) for (const observation of outcome.observations) console.log(`        ${observation}`);
    }
  }
  if (report.crossVersion.length) {
    console.log(`\n  cross-version ${archives.map(({ name }) => name).join(" ↔ ")}`);
    for (const outcome of report.crossVersion) {
      const mark = outcome.status === "passed" ? green("✓")
        : outcome.status === "failed" ? red("✗") : yellow("–");
      console.log(`    ${mark} ${outcome.id}${outcome.reason ? ` ${outcome.reason}` : ""}`);
    }
  }
  console.log(`\n${report.tally.passed} passed, ${report.tally.failed} failed, ${report.tally.skipped} skipped`);
}

if (releaseVerificationProblems(report).length) process.exitCode = 1;
