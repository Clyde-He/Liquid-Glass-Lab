// Derives the narrow macOS 27 slider model from canonical Golden Static rows.
import { admitArchive } from "./lib/archive.mjs";
import { cellKey, LEGACY_CELL_FIELDS } from "./lib/cell.mjs";
import { projectStyleSample } from "./lib/snapshot-projections.mjs";

const amounts = [0, 0.5, 1];
const numericKeys = [
  "inputBlurOpacity0", "inputBlurOpacity1", "inputBlurOpacity2", "inputBlurOpacity3",
  "inputBlurRadius", "inputBlurFillBlurRadius", "inputBlurFillNormalOpacity",
  "inputBlurFillLightenOpacity", "inputBlurFillDarkenOpacity",
  "inputFaceColorMatrixMaxLuma", "inputFaceColorMatrixMaxLumaSDR",
].sort();
const colorKeys = ["inputFaceColorMatrixFillColor"];

function projectAnchor(snapshot) {
  const sample = projectStyleSample(snapshot);
  if (!sample) throw new Error("Unprojectable native sample");
  const numeric = Object.fromEntries(numericKeys.map((key) => [key, sample.numeric[key]]));
  const colors = Object.fromEntries(colorKeys.map((key) => [key, sample.colors[key]]));
  if (!Object.values(numeric).every(Number.isFinite)
      || Object.values(colors).some((value) => !value)) {
    throw new Error("Incomplete tint-amount inputs");
  }
  return { numeric, colors, marginWidth: sample.marginWidth };
}

export async function modelFromAcceptedArchive(directory) {
  const archive = await admitArchive(directory);
  if (archive.platform.major !== 27
      || archive.capture?.transparency?.control !== "processOverridePerObservation") {
    throw new Error("Accepted Golden lacks canonical macOS 27 transparency coordinates");
  }

  const rows = new Map(archive.static.observations.map((observation) => [
    `${cellKey(observation.cell, LEGACY_CELL_FIELDS)}|${observation.cell.glassAmount}`,
    observation,
  ]));
  const midpoint = [...archive.static.consumerCells]
    .sort((left, right) => cellKey(left, LEGACY_CELL_FIELDS)
      .localeCompare(cellKey(right, LEGACY_CELL_FIELDS)));
  if (midpoint.length !== 56 || midpoint.some(({ glassAmount }) => glassAmount !== 0.5)) {
    throw new Error("Canonical Golden lacks the 56 midpoint Consumer coordinates");
  }

  const entries = midpoint.map((cell) => {
    const key = cellKey(cell, LEGACY_CELL_FIELDS);
    const anchors = amounts.map((amount) => rows.get(`${key}|${amount}`));
    if (anchors.some((row) => !row)) {
      throw new Error(`Canonical Golden lacks 0/0.5/1 anchors for ${key}`);
    }
    return {
      cell: {
        isLightAppearance: cell.appearance === "Light",
        isClear: cell.variant === 2,
        hasMainParticipation: cell.main,
      },
      shortSide: cell.shortSide,
      anchors: anchors.map(({ snapshot }) => projectAnchor(snapshot)),
    };
  });
  return { schemaVersion: 1, osMajorVersion: 27, entries };
}
