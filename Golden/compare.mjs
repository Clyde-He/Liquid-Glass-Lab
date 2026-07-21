#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function usage() {
  console.error(
    "Usage: node compare.mjs <baseline-dir> <candidate-dir> "
      + "[--fixture=recipe-matrix.json] [--tolerance=1e-6] [--limit=100] "
      + "[--include-volatile]"
  );
  process.exit(2);
}

const positional = process.argv.slice(2).filter((argument) => !argument.startsWith("--"));
if (positional.length !== 2) usage();

function option(name, fallback) {
  const prefix = `--${name}=`;
  const argument = process.argv.slice(2).find((value) => value.startsWith(prefix));
  return argument ? argument.slice(prefix.length) : fallback;
}

const baselineDirectory = path.resolve(positional[0]);
const candidateDirectory = path.resolve(positional[1]);
const fixtureName = option("fixture", "recipe-matrix.json");
const tolerance = Number(option("tolerance", "1e-6"));
const differenceLimit = Number(option("limit", "100"));
const includeVolatile = process.argv.slice(2).includes("--include-volatile");

// Values proven to change between active captures on the same OS build due to
// display/runtime environment rather than a Recipe axis. Raw fixtures retain
// them; the default semantic diff reports them separately.
const volatileFields = new Set([
  "inputs.inputMaxHeadroom",
]);

if (!Number.isFinite(tolerance) || tolerance < 0) {
  throw new Error(`Invalid tolerance: ${tolerance}`);
}
if (!Number.isInteger(differenceLimit) || differenceLimit < 1) {
  throw new Error(`Invalid difference limit: ${differenceLimit}`);
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function entries(document) {
  if (Array.isArray(document)) return document;
  if (Array.isArray(document.entries)) return document.entries;
  throw new Error("Fixture must be a JSON array or an object with an entries array.");
}

function scalar(value) {
  return value === null || value === undefined ? "<nil>" : String(value);
}

function identity(row, document) {
  if (Number.isInteger(row.roleTag) && "requestedMain" in row) {
    const context = document.context ?? {};
    return [
      "semantic",
      `host=${scalar(context.hostType)}`,
      `main=${scalar(row.requestedMain)}`,
      `size=${scalar(context.glassWidth)}x${scalar(context.glassHeight)}`
        + `@${scalar(context.cornerRadius)}`,
      `margin=${scalar(context.windowMargin)}`,
      `roleTag=${scalar(row.roleTag)}`,
    ].join("|");
  }

  return [
    scalar(row.context),
    `main=${scalar(row.requestedMain)}`,
    `subdued=${scalar(row.subdued)}`,
    `size=${scalar(row.glassWidth)}x${scalar(row.glassHeight)}@${scalar(row.cornerRadius)}`,
    `v=${scalar(row.variant)}`,
    `s=${scalar(row.subvariant)}`,
  ].join("|");
}

const axisKeys = new Set([
  "context",
  "requestedMain",
  "subdued",
  "glassWidth",
  "glassHeight",
  "cornerRadius",
  "variant",
  "subvariant",
  "roleTag",
]);

function flatten(value, prefix = "", output = new Map()) {
  if (Array.isArray(value)) {
    if (value.length === 0) output.set(prefix, "[]");
    for (const [index, item] of value.entries()) {
      flatten(item, `${prefix}[${index}]`, output);
    }
    return output;
  }
  if (value && typeof value === "object") {
    for (const key of Object.keys(value).sort()) {
      if (!prefix && axisKeys.has(key)) continue;
      flatten(value[key], prefix ? `${prefix}.${key}` : key, output);
    }
    return output;
  }
  output.set(prefix, value);
  return output;
}

function indexRows(rows, document, label) {
  const result = new Map();
  for (const row of rows) {
    const key = identity(row, document);
    if (result.has(key)) throw new Error(`${label} contains duplicate row identity: ${key}`);
    result.set(key, row);
  }
  return result;
}

function equal(lhs, rhs) {
  if (typeof lhs === "number" && typeof rhs === "number") {
    return Math.abs(lhs - rhs) <= tolerance;
  }
  return Object.is(lhs, rhs);
}

function isVolatileField(field, baselineValues, candidateValues) {
  if (volatileFields.has(field)) return true;
  if (!field.endsWith(".value")) return false;
  const keyField = `${field.slice(0, -".value".length)}.key`;
  return baselineValues.get(keyField) === "inputMaxHeadroom"
    || candidateValues.get(keyField) === "inputMaxHeadroom";
}

const baselinePath = path.join(baselineDirectory, fixtureName);
const candidatePath = path.join(candidateDirectory, fixtureName);
const baselineDocument = readJSON(baselinePath);
const candidateDocument = readJSON(candidatePath);
const baselineRows = indexRows(entries(baselineDocument), baselineDocument, "baseline");
const candidateRows = indexRows(entries(candidateDocument), candidateDocument, "candidate");

const missingRows = [...baselineRows.keys()].filter((key) => !candidateRows.has(key)).sort();
const addedRows = [...candidateRows.keys()].filter((key) => !baselineRows.has(key)).sort();
const differences = [];
const volatileDifferences = [];
let changedValues = 0;
let missingFields = 0;
let addedFields = 0;
let maxNumericDelta = 0;
let volatileChangedValues = 0;
let volatileMissingFields = 0;
let volatileAddedFields = 0;
let maxVolatileNumericDelta = 0;

for (const key of [...baselineRows.keys()].filter((rowKey) => candidateRows.has(rowKey)).sort()) {
  const baselineValues = flatten(baselineRows.get(key));
  const candidateValues = flatten(candidateRows.get(key));
  const fields = new Set([...baselineValues.keys(), ...candidateValues.keys()]);
  for (const field of [...fields].sort()) {
    const hasBaseline = baselineValues.has(field);
    const hasCandidate = candidateValues.has(field);
    const isVolatile = isVolatileField(field, baselineValues, candidateValues);
    if (!hasCandidate) {
      if (isVolatile) {
        volatileMissingFields += 1;
        if (volatileDifferences.length < differenceLimit) {
          volatileDifferences.push({ row: key, field, kind: "missing" });
        }
        if (!includeVolatile) continue;
      }
      missingFields += 1;
      if (differences.length < differenceLimit) differences.push({ row: key, field, kind: "missing" });
      continue;
    }
    if (!hasBaseline) {
      if (isVolatile) {
        volatileAddedFields += 1;
        if (volatileDifferences.length < differenceLimit) {
          volatileDifferences.push({ row: key, field, kind: "added" });
        }
        if (!includeVolatile) continue;
      }
      addedFields += 1;
      if (differences.length < differenceLimit) differences.push({ row: key, field, kind: "added" });
      continue;
    }
    const before = baselineValues.get(field);
    const after = candidateValues.get(field);
    if (!equal(before, after)) {
      const delta = typeof before === "number" && typeof after === "number"
        ? Math.abs(before - after)
        : undefined;
      if (isVolatile) {
        volatileChangedValues += 1;
        if (delta !== undefined) {
          maxVolatileNumericDelta = Math.max(maxVolatileNumericDelta, delta);
        }
        if (volatileDifferences.length < differenceLimit) {
          volatileDifferences.push({
            row: key, field, kind: "changed", before, after, delta,
          });
        }
        if (!includeVolatile) continue;
      }
      changedValues += 1;
      if (delta !== undefined) maxNumericDelta = Math.max(maxNumericDelta, delta);
      if (differences.length < differenceLimit) {
        differences.push({ row: key, field, kind: "changed", before, after, delta });
      }
    }
  }
}

const summary = {
  fixture: fixtureName,
  baseline: baselineDirectory,
  candidate: candidateDirectory,
  tolerance,
  includeVolatile,
  volatileFields: [...volatileFields].sort(),
  baselineRows: baselineRows.size,
  candidateRows: candidateRows.size,
  missingRows: missingRows.length,
  addedRows: addedRows.length,
  missingFields,
  addedFields,
  changedValues,
  maxNumericDelta,
  volatileMissingFields,
  volatileAddedFields,
  volatileChangedValues,
  maxVolatileNumericDelta,
  reportedDifferences: differences.length,
  reportedVolatileDifferences: volatileDifferences.length,
  truncated: changedValues + missingFields + addedFields > differences.length,
  volatileTruncated:
    volatileChangedValues + volatileMissingFields + volatileAddedFields
      > volatileDifferences.length,
};

console.log(JSON.stringify({
  summary,
  missingRowIdentities: missingRows.slice(0, differenceLimit),
  addedRowIdentities: addedRows.slice(0, differenceLimit),
  differences,
  volatileDifferences,
}, null, 2));
