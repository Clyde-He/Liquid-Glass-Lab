#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function usage() {
  console.error(
    "Usage: node compare.mjs <baseline-dir> <candidate-dir> "
      + "[--fixture=recipe-matrix.json|recursive-pass-audit.json] "
      + "[--recursive-mode=semantic|raw] "
      + "[--tolerance=1e-6] [--limit=100] "
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
const isPassAudit = fixtureName === "recursive-pass-audit.json";
const recursiveMode = option("recursive-mode", "semantic");

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
if (isPassAudit && !new Set(["semantic", "raw"]).has(recursiveMode)) {
  throw new Error(`Invalid Recursive comparison mode: ${recursiveMode}`);
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
      if (isPassAudit && prefix === "snapshot"
          && (key === "topologySignature" || key === "valueSignature")) continue;
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
  if (field.includes(".properties.inputMaxHeadroom.")) return true;
  if (!field.endsWith(".value")) return false;
  const keyField = `${field.slice(0, -".value".length)}.key`;
  return baselineValues.get(keyField) === "inputMaxHeadroom"
    || candidateValues.get(keyField) === "inputMaxHeadroom";
}

function numericDescription(value) {
  if (typeof value === "number") return value;
  if (typeof value !== "string") return undefined;
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value)) {
    return undefined;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function semanticEqual(field, lhs, rhs) {
  if (!field.endsWith(".value")) return equal(lhs, rhs);
  const leftNumber = numericDescription(lhs);
  const rightNumber = numericDescription(rhs);
  if (leftNumber === undefined || rightNumber === undefined) return equal(lhs, rhs);
  return Math.abs(leftNumber - rightNumber) <= tolerance;
}

function semanticDelta(field, lhs, rhs) {
  if (!field.endsWith(".value")) return undefined;
  const leftNumber = numericDescription(lhs);
  const rightNumber = numericDescription(rhs);
  return leftNumber === undefined || rightNumber === undefined
    ? undefined
    : Math.abs(leftNumber - rightNumber);
}

function passChannel(pass) {
  return scalar(pass.location).replace(/\[\d+\]$/, "");
}

function passFamily(pass) {
  return scalar(pass.name ?? pass.objectClass);
}

function passGroupIdentity(pass) {
  return `${passChannel(pass)}|${passFamily(pass)}`;
}

function passSortIdentity(pass) {
  return [pass.layerPath, pass.location, pass.objectClass, pass.name, pass.id]
    .map(scalar)
    .join("|");
}

function layerPathTokens(layerPath) {
  const tokens = [];
  const pattern = /(?:^root|\.sublayers\[(\d+)\]|\.mask):([^.|]+)/g;
  let match;
  while ((match = pattern.exec(layerPath ?? "")) !== null) {
    tokens.push(`${match[1] ?? "root"}:${match[2]}`);
  }
  const sdfRoot = tokens.findIndex((token) => token.endsWith(":SDFLayer"));
  return sdfRoot >= 0 ? tokens.slice(sdfRoot) : tokens;
}

function sequenceEditDistance(lhs, rhs) {
  let previous = Array.from({ length: rhs.length + 1 }, (_, index) => index);
  for (let leftIndex = 0; leftIndex < lhs.length; leftIndex += 1) {
    const current = [leftIndex + 1];
    for (let rightIndex = 0; rightIndex < rhs.length; rightIndex += 1) {
      current.push(Math.min(
        current[rightIndex] + 1,
        previous[rightIndex + 1] + 1,
        previous[rightIndex] + (lhs[leftIndex] === rhs[rightIndex] ? 0 : 1)
      ));
    }
    previous = current;
  }
  return previous[rhs.length];
}

function symmetricKeyDifference(lhs, rhs) {
  const left = new Set(Object.keys(lhs ?? {}));
  const right = new Set(Object.keys(rhs ?? {}));
  return [...left].filter((key) => !right.has(key)).length
    + [...right].filter((key) => !left.has(key)).length;
}

function passMatchCost(baselinePass, candidatePass) {
  const pathCost = sequenceEditDistance(
    layerPathTokens(baselinePass.layerPath),
    layerPathTokens(candidatePass.layerPath)
  );
  const ownerClassCost = baselinePass.layerClass === candidatePass.layerClass ? 0 : 20;
  const locationCost = baselinePass.location === candidatePass.location ? 0 : 5;
  const propertyCost = symmetricKeyDifference(
    baselinePass.properties,
    candidatePass.properties
  );
  return pathCost * 10 + ownerClassCost + locationCost + propertyCost;
}

function minimumCostPassPairs(baselinePasses, candidatePasses) {
  const baseline = [...baselinePasses].sort((lhs, rhs) =>
    passSortIdentity(lhs).localeCompare(passSortIdentity(rhs)));
  const candidate = [...candidatePasses].sort((lhs, rhs) =>
    passSortIdentity(lhs).localeCompare(passSortIdentity(rhs)));
  const baselineIsShorter = baseline.length <= candidate.length;
  const source = baselineIsShorter ? baseline : candidate;
  const target = baselineIsShorter ? candidate : baseline;
  let best;

  function search(sourceIndex, availableTargetIndexes, pairs, cost) {
    if (sourceIndex === source.length) {
      if (!best || cost < best.cost) best = { cost, pairs: [...pairs] };
      return;
    }
    for (const targetIndex of availableTargetIndexes) {
      const sourcePass = source[sourceIndex];
      const targetPass = target[targetIndex];
      const pairCost = baselineIsShorter
        ? passMatchCost(sourcePass, targetPass)
        : passMatchCost(targetPass, sourcePass);
      if (best && cost + pairCost > best.cost) continue;
      pairs.push(baselineIsShorter
        ? [sourcePass, targetPass]
        : [targetPass, sourcePass]);
      search(
        sourceIndex + 1,
        availableTargetIndexes.filter((index) => index !== targetIndex),
        pairs,
        cost + pairCost
      );
      pairs.pop();
    }
  }

  search(0, target.map((_, index) => index), [], 0);
  const pairs = best?.pairs ?? [];
  const pairedBaseline = new Set(pairs.map(([pass]) => pass));
  const pairedCandidate = new Set(pairs.map(([, pass]) => pass));
  return {
    pairs,
    unmatchedBaseline: baseline.filter((pass) => !pairedBaseline.has(pass)),
    unmatchedCandidate: candidate.filter((pass) => !pairedCandidate.has(pass)),
  };
}

function passGroups(row) {
  const groups = new Map();
  for (const pass of Object.values(row.snapshot?.passes ?? {})) {
    const key = passGroupIdentity(pass);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(pass);
  }
  return groups;
}

function passProjection(pass) {
  return {
    layerClass: pass.layerClass ?? null,
    location: pass.location ?? null,
    name: pass.name ?? null,
    objectClass: pass.objectClass ?? null,
    properties: pass.properties ?? {},
  };
}

function addAggregate(map, key, fields, row) {
  if (!map.has(key)) map.set(key, { ...fields, count: 0, rows: new Set() });
  const item = map.get(key);
  item.count += 1;
  item.rows.add(row);
}

function aggregateValues(map) {
  return [...map.values()]
    .map(({ rows, ...item }) => ({ ...item, rowCount: rows.size }))
    .sort((lhs, rhs) => rhs.count - lhs.count
      || JSON.stringify(lhs).localeCompare(JSON.stringify(rhs)));
}

function comparePassAuditsSemantically(
  baselineRows,
  candidateRows,
  missingRows,
  addedRows
) {
  const differences = [];
  const volatileDifferences = [];
  const inventoryChanges = new Map();
  const classChanges = new Map();
  const propertyInventoryChanges = new Map();
  const propertyValueChanges = new Map();
  let matchedPasses = 0;
  let missingPasses = 0;
  let addedPasses = 0;
  let missingProperties = 0;
  let addedProperties = 0;
  let changedValues = 0;
  let missingFields = 0;
  let addedFields = 0;
  let maxNumericDelta = 0;
  let volatileChangedValues = 0;
  let volatileMissingFields = 0;
  let volatileAddedFields = 0;
  let maxVolatileNumericDelta = 0;
  let passObjectClassChanges = 0;
  let passOwnerClassChanges = 0;
  let topologyChangedRows = 0;
  let valueChangedRows = 0;

  const matchedRowKeys = [...baselineRows.keys()]
    .filter((key) => candidateRows.has(key))
    .sort();
  for (const rowKey of matchedRowKeys) {
    const baselineRow = baselineRows.get(rowKey);
    const candidateRow = candidateRows.get(rowKey);
    if (baselineRow.snapshot?.topologySignature
        !== candidateRow.snapshot?.topologySignature) topologyChangedRows += 1;
    if (baselineRow.snapshot?.valueSignature
        !== candidateRow.snapshot?.valueSignature) valueChangedRows += 1;

    const baselineGroups = passGroups(baselineRow);
    const candidateGroups = passGroups(candidateRow);
    const groupKeys = [...new Set([
      ...baselineGroups.keys(),
      ...candidateGroups.keys(),
    ])].sort();
    for (const groupKey of groupKeys) {
      const baselineGroup = baselineGroups.get(groupKey) ?? [];
      const candidateGroup = candidateGroups.get(groupKey) ?? [];
      const [channel, family] = groupKey.split("|");
      const match = minimumCostPassPairs(baselineGroup, candidateGroup);
      const orderedPairs = [...match.pairs].sort(([left], [right]) =>
        passSortIdentity(left).localeCompare(passSortIdentity(right)));

      for (const pass of match.unmatchedBaseline) {
        missingPasses += 1;
        addAggregate(
          inventoryChanges,
          `missing|${groupKey}`,
          { kind: "missing", channel, family },
          rowKey
        );
        if (differences.length < differenceLimit) {
          differences.push({
            row: rowKey,
            field: `passes.${channel}:${family}`,
            kind: "missingPass",
            before: passProjection(pass),
          });
        }
      }
      for (const pass of match.unmatchedCandidate) {
        addedPasses += 1;
        addAggregate(
          inventoryChanges,
          `added|${groupKey}`,
          { kind: "added", channel, family },
          rowKey
        );
        if (differences.length < differenceLimit) {
          differences.push({
            row: rowKey,
            field: `passes.${channel}:${family}`,
            kind: "addedPass",
            after: passProjection(pass),
          });
        }
      }

      for (const [pairIndex, [baselinePass, candidatePass]] of orderedPairs.entries()) {
        matchedPasses += 1;
        const passPrefix = `passes.${channel}:${family}#${pairIndex + 1}`;
        if (baselinePass.objectClass !== candidatePass.objectClass) {
          passObjectClassChanges += 1;
          addAggregate(
            classChanges,
            `object|${groupKey}|${baselinePass.objectClass}|${candidatePass.objectClass}`,
            {
              field: "objectClass",
              channel,
              family,
              before: baselinePass.objectClass ?? null,
              after: candidatePass.objectClass ?? null,
            },
            rowKey
          );
        }
        if (baselinePass.layerClass !== candidatePass.layerClass) {
          passOwnerClassChanges += 1;
          addAggregate(
            classChanges,
            `owner|${groupKey}|${baselinePass.layerClass}|${candidatePass.layerClass}`,
            {
              field: "layerClass",
              channel,
              family,
              before: baselinePass.layerClass ?? null,
              after: candidatePass.layerClass ?? null,
            },
            rowKey
          );
        }

        const baselinePropertyKeys = new Set(Object.keys(baselinePass.properties ?? {}));
        const candidatePropertyKeys = new Set(Object.keys(candidatePass.properties ?? {}));
        for (const property of baselinePropertyKeys) {
          if (candidatePropertyKeys.has(property)) continue;
          missingProperties += 1;
          addAggregate(
            propertyInventoryChanges,
            `missing|${groupKey}|${property}`,
            { kind: "missing", channel, family, property },
            rowKey
          );
        }
        for (const property of candidatePropertyKeys) {
          if (baselinePropertyKeys.has(property)) continue;
          addedProperties += 1;
          addAggregate(
            propertyInventoryChanges,
            `added|${groupKey}|${property}`,
            { kind: "added", channel, family, property },
            rowKey
          );
        }

        const baselineValues = flatten(passProjection(baselinePass), passPrefix);
        const candidateValues = flatten(passProjection(candidatePass), passPrefix);
        const fields = new Set([...baselineValues.keys(), ...candidateValues.keys()]);
        for (const field of [...fields].sort()) {
          const hasBaseline = baselineValues.has(field);
          const hasCandidate = candidateValues.has(field);
          const isVolatile = isVolatileField(field, baselineValues, candidateValues);
          if (!hasCandidate) {
            if (isVolatile) {
              volatileMissingFields += 1;
              if (volatileDifferences.length < differenceLimit) {
                volatileDifferences.push({ row: rowKey, field, kind: "missing" });
              }
              if (!includeVolatile) continue;
            }
            missingFields += 1;
            if (differences.length < differenceLimit) {
              differences.push({ row: rowKey, field, kind: "missing" });
            }
            continue;
          }
          if (!hasBaseline) {
            if (isVolatile) {
              volatileAddedFields += 1;
              if (volatileDifferences.length < differenceLimit) {
                volatileDifferences.push({ row: rowKey, field, kind: "added" });
              }
              if (!includeVolatile) continue;
            }
            addedFields += 1;
            if (differences.length < differenceLimit) {
              differences.push({ row: rowKey, field, kind: "added" });
            }
            continue;
          }

          const before = baselineValues.get(field);
          const after = candidateValues.get(field);
          if (semanticEqual(field, before, after)) continue;
          const delta = semanticDelta(field, before, after);
          if (isVolatile) {
            volatileChangedValues += 1;
            if (delta !== undefined) {
              maxVolatileNumericDelta = Math.max(maxVolatileNumericDelta, delta);
            }
            if (volatileDifferences.length < differenceLimit) {
              volatileDifferences.push({
                row: rowKey, field, kind: "changed", before, after, delta,
              });
            }
            if (!includeVolatile) continue;
          }
          changedValues += 1;
          if (delta !== undefined) maxNumericDelta = Math.max(maxNumericDelta, delta);
          if (differences.length < differenceLimit) {
            differences.push({ row: rowKey, field, kind: "changed", before, after, delta });
          }
          const propertyMatch = field.match(/\.properties\.([^.]+)\.value$/);
          if (propertyMatch) {
            const property = propertyMatch[1];
            const aggregateKey = `${groupKey}|${property}`;
            if (!propertyValueChanges.has(aggregateKey)) {
              propertyValueChanges.set(aggregateKey, {
                channel,
                family,
                property,
                count: 0,
                rows: new Set(),
                maxNumericDelta: 0,
                example: { before, after },
              });
            }
            const aggregate = propertyValueChanges.get(aggregateKey);
            aggregate.count += 1;
            aggregate.rows.add(rowKey);
            if (delta !== undefined) {
              aggregate.maxNumericDelta = Math.max(aggregate.maxNumericDelta, delta);
            }
          }
        }
      }
    }
  }

  const totalPasses = (rows) => [...rows.values()].reduce(
    (total, row) => total + Object.keys(row.snapshot?.passes ?? {}).length,
    0
  );
  const propertyValueChangeSummary = [...propertyValueChanges.values()]
    .map(({ rows, ...item }) => ({ ...item, rowCount: rows.size }))
    .sort((lhs, rhs) => rhs.count - lhs.count
      || `${lhs.channel}|${lhs.family}|${lhs.property}`
        .localeCompare(`${rhs.channel}|${rhs.family}|${rhs.property}`));
  const passInventoryChangeSummary = aggregateValues(inventoryChanges);
  const passClassChangeSummary = aggregateValues(classChanges);
  const propertyInventoryChangeSummary = aggregateValues(propertyInventoryChanges);
  const summary = {
    fixture: fixtureName,
    recursiveMode: "semantic",
    semanticScope: "pass inventory, pass metadata, and pass properties",
    baseline: baselineDirectory,
    candidate: candidateDirectory,
    tolerance,
    includeVolatile,
    volatileFields: [...volatileFields].sort(),
    baselineRows: baselineRows.size,
    candidateRows: candidateRows.size,
    missingRows: missingRows.length,
    addedRows: addedRows.length,
    baselinePasses: totalPasses(baselineRows),
    candidatePasses: totalPasses(candidateRows),
    matchedPasses,
    missingPasses,
    addedPasses,
    missingProperties,
    addedProperties,
    passObjectClassChanges,
    passOwnerClassChanges,
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
    truncated: missingPasses + addedPasses + missingFields + addedFields + changedValues
      > differences.length,
    volatileTruncated:
      volatileChangedValues + volatileMissingFields + volatileAddedFields
        > volatileDifferences.length,
    baselineTopologySignatures: new Set(
      [...baselineRows.values()].map((row) => row.snapshot?.topologySignature)
    ).size,
    candidateTopologySignatures: new Set(
      [...candidateRows.values()].map((row) => row.snapshot?.topologySignature)
    ).size,
    baselineValueSignatures: new Set(
      [...baselineRows.values()].map((row) => row.snapshot?.valueSignature)
    ).size,
    candidateValueSignatures: new Set(
      [...candidateRows.values()].map((row) => row.snapshot?.valueSignature)
    ).size,
    rawTopologyChangedRows: topologyChangedRows,
    rawValueChangedRows: valueChangedRows,
  };

  return {
    summary,
    missingRowIdentities: missingRows.slice(0, differenceLimit),
    addedRowIdentities: addedRows.slice(0, differenceLimit),
    passInventoryChanges: passInventoryChangeSummary.slice(0, differenceLimit),
    passInventoryChangesTruncated: passInventoryChangeSummary.length > differenceLimit,
    passClassChanges: passClassChangeSummary.slice(0, differenceLimit),
    passClassChangesTruncated: passClassChangeSummary.length > differenceLimit,
    propertyInventoryChanges: propertyInventoryChangeSummary.slice(0, differenceLimit),
    propertyInventoryChangesTruncated:
      propertyInventoryChangeSummary.length > differenceLimit,
    propertyValueChanges: propertyValueChangeSummary.slice(0, differenceLimit),
    propertyValueChangesTruncated: propertyValueChangeSummary.length > differenceLimit,
    differences,
    volatileDifferences,
  };
}

const baselinePath = path.join(baselineDirectory, fixtureName);
const candidatePath = path.join(candidateDirectory, fixtureName);
const baselineDocument = readJSON(baselinePath);
const candidateDocument = readJSON(candidatePath);
const baselineRows = indexRows(entries(baselineDocument), baselineDocument, "baseline");
const candidateRows = indexRows(entries(candidateDocument), candidateDocument, "candidate");

const missingRows = [...baselineRows.keys()].filter((key) => !candidateRows.has(key)).sort();
const addedRows = [...candidateRows.keys()].filter((key) => !baselineRows.has(key)).sort();

if (isPassAudit && recursiveMode === "semantic") {
  console.log(JSON.stringify(comparePassAuditsSemantically(
    baselineRows,
    candidateRows,
    missingRows,
    addedRows
  ), null, 2));
  process.exit(0);
}

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
let topologyChangedRows = 0;
let valueChangedRows = 0;

for (const key of [...baselineRows.keys()].filter((rowKey) => candidateRows.has(rowKey)).sort()) {
  const baselineRow = baselineRows.get(key);
  const candidateRow = candidateRows.get(key);
  if (isPassAudit) {
    if (baselineRow.snapshot?.topologySignature
        !== candidateRow.snapshot?.topologySignature) topologyChangedRows += 1;
    if (baselineRow.snapshot?.valueSignature
        !== candidateRow.snapshot?.valueSignature) valueChangedRows += 1;
  }
  const baselineValues = flatten(baselineRow);
  const candidateValues = flatten(candidateRow);
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
  ...(isPassAudit ? { recursiveMode: "raw" } : {}),
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
  ...(isPassAudit ? {
    baselineTopologySignatures: new Set(
      [...baselineRows.values()].map((row) => row.snapshot?.topologySignature)
    ).size,
    candidateTopologySignatures: new Set(
      [...candidateRows.values()].map((row) => row.snapshot?.topologySignature)
    ).size,
    baselineValueSignatures: new Set(
      [...baselineRows.values()].map((row) => row.snapshot?.valueSignature)
    ).size,
    candidateValueSignatures: new Set(
      [...candidateRows.values()].map((row) => row.snapshot?.valueSignature)
    ).size,
    topologyChangedRows,
    valueChangedRows,
  } : {}),
};

console.log(JSON.stringify({
  summary,
  missingRowIdentities: missingRows.slice(0, differenceLimit),
  addedRowIdentities: addedRows.slice(0, differenceLimit),
  differences,
  volatileDifferences,
}, null, 2));
