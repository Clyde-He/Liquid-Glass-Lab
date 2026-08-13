#!/usr/bin/env node

import path from "node:path";
import { admitArchive, compareArchives } from "./lib/archive.mjs";

const args = process.argv.slice(2);
const positional = args.filter((argument) => !argument.startsWith("--"));
if (positional.length !== 2 || args.some((argument) => !positional.includes(argument)
  && argument !== "--check")) {
  console.error("usage: compare.mjs <baseline-archive> <candidate-archive> [--check]");
  process.exit(64);
}

const baseline = await admitArchive(path.resolve(positional[0]));
const candidate = await admitArchive(path.resolve(positional[1]));
const report = compareArchives(baseline, candidate);
process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
if (args.includes("--check") && !report.equivalent) process.exitCode = 1;
