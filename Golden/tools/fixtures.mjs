#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { admitArchive } from "./lib/archive.mjs";
import {
  projectBackdropScale, projectStyleSample,
} from "./lib/snapshot-projections.mjs";

const canonicalValue = (value) => {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])])
    );
  }
  return value;
};
const canonical = (value) => JSON.stringify(canonicalValue(value));
const root = fileURLToPath(new URL("../", import.meta.url));
const archive = await admitArchive(path.join(root, "macOS-27"));
if (archive.capture?.transparency?.control !== "processOverridePerObservation") {
  throw new Error("Accepted Golden lacks canonical macOS 27 transparency coordinates");
}

const observations = archive.static.observations.filter(({ cell }) =>
  [1, 2].includes(cell.variant) && cell.subvariant === null
    && typeof cell.main === "boolean" && cell.key === false && cell.subdued === false
    && ["Light", "Dark"].includes(cell.appearance) && cell.backdrop === "Light"
    && cell.tint === "None" && cell.cornerRadius === 16 && cell.host === "Panel"
    && Number.isFinite(cell.glassAmount) && cell.glassAmount !== 0.5);
const fixtureID = ({ cell }) => JSON.stringify([
  cell.appearance, cell.variant, cell.main, cell.shortSide, cell.glassAmount,
]);
observations.sort((left, right) => fixtureID(left).localeCompare(fixtureID(right)));
const rows = observations.map(({ cell, snapshot }) => ({
  amount: cell.glassAmount,
  cell: {
    isLightAppearance: cell.appearance === "Light",
    isClear: cell.variant === 2,
    hasMainParticipation: cell.main,
  },
  expected: projectStyleSample(snapshot),
  scale: projectBackdropScale(snapshot),
}));

if (rows.length === 0
    || new Set(observations.map(fixtureID)).size !== observations.length
    || rows.some(({ expected, scale }) => !expected || !Number.isFinite(scale))) {
  throw new Error("Canonical Golden has incomplete or duplicate tint-amount fixture rows");
}

const output = path.join(
  root, "../Tests/AdjustableGlassTests/Fixtures/native-tint-amount.json"
);
if (process.argv.includes("--check")) {
  const actual = JSON.parse(await readFile(output, "utf8"));
  const normalize = (values) => values.map(canonical).sort();
  if (canonical(normalize(actual)) !== canonical(normalize(rows))) {
    throw new Error("Bundled tint-amount fixture is stale");
  }
} else {
  await writeFile(output, `${JSON.stringify(rows, null, 2)}\n`);
}
console.error(`${rows.length} native tint-amount observations projected from accepted Golden`);
