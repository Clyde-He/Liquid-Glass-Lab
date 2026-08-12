import { cellKey } from "./cell.mjs";
import { projectStyleSample } from "./snapshot-projections.mjs";

function catalogCell(cell) {
  if (!["Light", "Dark"].includes(cell?.appearance)
      || ![1, 2].includes(cell?.variant)
      || typeof cell?.main !== "boolean"
      || cell.subvariant !== null || cell.key !== false || cell.subdued !== false
      || cell.backdrop !== "Light" || cell.tint !== "None"
      || cell.width !== 480 || cell.height !== cell.shortSide
      || cell.cornerRadius !== 16 || cell.host !== "Panel" || cell.direction !== null
      || !Number.isFinite(cell.shortSide)) return null;
  return {
    isLightAppearance: cell.appearance === "Light",
    isClear: cell.variant === 2,
    hasMainParticipation: cell.main,
  };
}

const catalogCellKey = (cell) => JSON.stringify([
  cell.isLightAppearance, cell.isClear, cell.hasMainParticipation,
]);

function supported(sample) {
  return sample && sample.matrices?.length === 2
    && sample.matrices.every(({ matrix }) => matrix?.length === 20)
    && sample.rims?.length === 1
    && sample.rims.every(({ values, colors }) => Object.keys(values ?? {}).length > 0
      && colors?.fillColor && colors?.keyColor);
}

export function verifiesMainOn(mainOn, mainOff) {
  if (!supported(mainOn) || !supported(mainOff)
      || Math.abs(mainOn.shortSide - mainOff.shortSide) >= 0.001) return false;
  const marginSeparation = mainOn.marginWidth - mainOff.marginWidth;
  const minimumMarginSeparation = Math.max(2, mainOn.shortSide * 0.05);
  const rimSeparation = mainOn.rims[0].layerOpacity - mainOff.rims[0].layerOpacity;
  let separatedNumericCount = 0;
  for (const key of Object.keys(mainOn.numeric)) {
    const left = mainOn.numeric[key];
    const right = mainOff.numeric[key];
    if (!Number.isFinite(left) || !Number.isFinite(right)) continue;
    const scale = Math.max(Math.abs(left), Math.abs(right), 1);
    if (Math.abs(left - right) / scale >= 0.01) separatedNumericCount += 1;
  }
  return rimSeparation >= 0.5
    && (marginSeparation >= minimumMarginSeparation || separatedNumericCount >= 3);
}

export function catalogFromSamples(capture, platform, entries) {
  const groups = new Map();
  for (const { cell, sample } of entries) {
    const projectedCell = catalogCell(cell);
    if (!projectedCell || !supported(sample)
        || Math.abs(sample.shortSide - cell.shortSide) >= 0.001) {
      throw new Error(`Consumer cell ${cellKey(cell)} is not a complete supported projection`);
    }
    const key = catalogCellKey(projectedCell);
    if (!groups.has(key)) groups.set(key, { cell: projectedCell, samples: [] });
    groups.get(key).samples.push(sample);
  }
  const ordered = [...groups.values()].sort((left, right) => {
    const lhs = catalogCellKey(left.cell);
    const rhs = catalogCellKey(right.cell);
    return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
  });
  if (ordered.length !== 8) throw new Error(`Catalog needs 8 cells; got ${ordered.length}`);
  let shortSides = null;
  for (const group of ordered) {
    group.samples.sort((left, right) => left.shortSide - right.shortSide);
    const sides = group.samples.map(({ shortSide }) => shortSide);
    if (sides.length === 0 || new Set(sides).size !== sides.length) {
      throw new Error(`Catalog cell ${catalogCellKey(group.cell)} has duplicate or empty sizes`);
    }
    if (shortSides === null) shortSides = sides;
    else if (JSON.stringify(sides) !== JSON.stringify(shortSides)) {
      throw new Error(`Catalog cells do not share one short-side grid: ${sides.join(", ")}`);
    }
  }
  for (const on of ordered.filter(({ cell }) => cell.hasMainParticipation)) {
    const off = ordered.find(({ cell }) => cell.isLightAppearance === on.cell.isLightAppearance
      && cell.isClear === on.cell.isClear && !cell.hasMainParticipation);
    if (!off || on.samples.some((sample, index) => !verifiesMainOn(sample, off.samples[index]))) {
      throw new Error(`Catalog cell ${catalogCellKey(on.cell)} has no valid Main-Off witness`);
    }
  }
  return {
    cells: ordered.flatMap(({ cell, samples }) => [cell, samples]),
    environment: {
      schemaVersion: 2,
      osBuild: capture.operatingSystem,
      displaySignature: capture.displaySignature,
      osMajorVersion: platform.major,
    },
    tintMatrices: [],
  };
}

export function catalogFromArchive(archive) {
  const observations = new Map(
    archive.static.observations.map((observation) => [cellKey(observation.cell), observation])
  );
  return catalogFromSamples(archive.capture, archive.platform,
    archive.static.consumerCells.map((cell) => {
      const observation = observations.get(cellKey(cell));
      return { cell, sample: observation && projectStyleSample(observation.snapshot) };
    }));
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}

export function catalogBytes(document) {
  return Buffer.from(`${JSON.stringify(canonical(document))}\n`);
}
