#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const LUMA = [0.2126, 0.7152, 0.0722];
const STRUCTURE_TOLERANCE = 2e-4;
const SOURCE_TOLERANCE = 2e-4;
const STANDARD_TOLERANCE = 2e-3;
const ALPHA_SWEEP_TOLERANCE = 2e-4;
const PARAMETERIZED_MATRIX_TOLERANCE = 2e-4;
const ACHROMATIC_CHROMA_THRESHOLD = 0.00035;
// Swift stores the residuals after doing the fit with Float matrix
// coefficients, while this analyzer repeats it in JavaScript Number. The
// classification tolerance is unchanged; this looser comparison only checks
// that optional derived metadata still describes the same measurement.
const STORED_RESIDUAL_TOLERANCE = 1e-7;

function maximum(values) {
  return values.length === 0 ? 0 : Math.max(...values);
}

function maximumDifference(left, right, excluded = new Set()) {
  if (left.length !== right.length) return Infinity;
  let result = 0;
  for (let index = 0; index < left.length; index += 1) {
    if (!excluded.has(index)) {
      result = Math.max(result, Math.abs(left[index] - right[index]));
    }
  }
  return result;
}

function cellKey(cell) {
  return [
    cell.isLightAppearance ? "Light" : "Dark",
    cell.isClear ? "Clear" : "Regular",
    cell.hasMainParticipation ? "Main-On" : "Main-Off",
  ].join(" · ");
}

function lumaEndpointInfo(matrix) {
  const denominator = LUMA.reduce(
    (sum, component) => sum + component * component,
    0
  );
  const bright = [];
  const dark = [];
  let maximumResidual = 0;
  for (let row = 0; row < 3; row += 1) {
    const offset = row * 5;
    const coefficients = matrix.slice(offset, offset + 3);
    const scale =
      coefficients.reduce(
        (sum, coefficient, index) => sum + coefficient * LUMA[index],
        0
      ) / denominator;
    for (let column = 0; column < 3; column += 1) {
      maximumResidual = Math.max(
        maximumResidual,
        Math.abs(coefficients[column] - scale * LUMA[column])
      );
    }
    dark.push(matrix[offset + 4]);
    bright.push(scale + matrix[offset + 4]);
  }
  return { bright, dark, maximumResidual };
}

function neutralSuppressionResidual(matrix, isLightAppearance) {
  const bias = isLightAppearance ? -0.1 : 0.1;
  let result = 0;
  for (let row = 0; row < 3; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      const expected = (row === column ? 0.7 : 0) + 0.3 * LUMA[column];
      result = Math.max(
        result,
        Math.abs(matrix[row * 5 + column] - expected)
      );
    }
    result = Math.max(result, Math.abs(matrix[row * 5 + 4] - bias));
  }
  return result;
}

function achromaticChannelAffineInfo(matrix) {
  const diagonal =
    (matrix[0] + matrix[6] + matrix[12]) / 3;
  const bias =
    (matrix[4] + matrix[9] + matrix[14]) / 3;
  let maximumResidual = 0;
  for (let row = 0; row < 3; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      maximumResidual = Math.max(
        maximumResidual,
        Math.abs(matrix[row * 5 + column] - (
          row === column ? diagonal : 0
        ))
      );
    }
    maximumResidual = Math.max(
      maximumResidual,
      Math.abs(matrix[row * 5 + 4] - bias)
    );
  }
  return { diagonal, bias, maximumResidual };
}

function achromaticFormulaResidual(matrix, color, alphaResidual) {
  const rgb = [color.red, color.green, color.blue];
  if (maximum(rgb) - Math.min(...rgb) > SOURCE_TOLERANCE) return null;
  const value = rgb.reduce((sum, component) => sum + component, 0) / 3;
  const denominator = 1 + 0.05 * value * (1 - value);
  const diagonal = 0.3125 / denominator;
  const bias = (1.1875 * value - 0.25) / denominator;
  let residual = alphaResidual;
  for (let row = 0; row < 3; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      const expected = row === column ? diagonal : 0;
      residual = Math.max(
        residual,
        Math.abs(matrix[row * 5 + column] - expected)
      );
    }
    residual = Math.max(
      residual,
      Math.abs(matrix[row * 5 + 4] - bias)
    );
  }
  return residual;
}

function alphaRowResidual(matrix, alpha) {
  return maximum([
    Math.abs(matrix[3]),
    Math.abs(matrix[8]),
    Math.abs(matrix[13]),
    Math.abs(matrix[15]),
    Math.abs(matrix[16]),
    Math.abs(matrix[17]),
    Math.abs(matrix[18] - alpha),
    Math.abs(matrix[19]),
  ]);
}

function lumaEndpointMatrix(bright, dark, alpha) {
  const matrix = Array(20).fill(0);
  for (let row = 0; row < 3; row += 1) {
    const scale = bright[row] - dark[row];
    for (let column = 0; column < 3; column += 1) {
      matrix[row * 5 + column] = scale * LUMA[column];
    }
    matrix[row * 5 + 4] = dark[row];
  }
  matrix[18] = alpha;
  return matrix;
}

function neutralSuppressionMatrix(isLightAppearance, alpha) {
  const matrix = Array(20).fill(0);
  [
    0.76378, 0.21450812, 0.021711912,
    0.0637902, 0.9145575, 0.021652289,
    0.06374377, 0.21459627, 0.72166,
  ].forEach((value, index) => {
    const row = Math.floor(index / 3);
    const column = index % 3;
    matrix[row * 5 + column] = value;
  });
  if (isLightAppearance) {
    matrix[4] = -0.100000024;
    matrix[9] = -0.100000024;
    matrix[14] = -0.100000024;
  } else {
    matrix[4] = 0.100000024;
    matrix[9] = 0.099999964;
    matrix[14] = 0.099999964;
  }
  matrix[18] = alpha;
  return matrix;
}

function achromaticMatrix(color) {
  const value = (color.red + color.green + color.blue) / 3;
  const denominator = 1 + 0.05 * value * (1 - value);
  const diagonal = 0.3125 / denominator;
  const bias = (1.1875 * value - 0.25) / denominator;
  const matrix = Array(20).fill(0);
  for (let row = 0; row < 3; row += 1) {
    matrix[row * 5 + row] = diagonal;
    matrix[row * 5 + 4] = bias;
  }
  matrix[18] = color.alpha;
  return matrix;
}

function standardDarkEndpoint(source) {
  const minimum = Math.min(...source);
  const maximum = Math.max(...source);
  const lightness = (minimum + maximum) / 2;
  let chromaScale;
  if (lightness <= 0.5) {
    chromaScale = 57 / 85;
  } else if (lightness <= 5 / 6) {
    chromaScale =
      ((87 / 5) * lightness - 3) / (17 * (1 - lightness));
  } else {
    chromaScale =
      (21 / 17 - (57 / 85) * lightness) / (1 - lightness);
  }
  const targetLightness = (9 / 17) * lightness;
  return source.map((component) => {
    const provisional =
      targetLightness + chromaScale * (component - lightness);
    const lowerBound = (-3 / 17) * component;
    const upperBound = (20 - 3 * component) / 17;
    return Math.min(Math.max(provisional, lowerBound), upperBound);
  });
}

function pastelEndpoint(source, isBright) {
  const minimum = Math.min(...source);
  const maximum = Math.max(...source);
  const chroma = maximum - minimum;
  const lightness = (minimum + maximum) / 2;
  let targetLightness;
  let chromaScale;
  if (isBright) {
    targetLightness =
      lightness <= 10 / 11
        ? (137 / 120) * lightness
        : 17 / 12 - (5 / 12) * lightness;
    if (lightness <= 5 / 11) {
      chromaScale = 851 / 800;
    } else if (lightness <= 0.5) {
      chromaScale = -4553 / 2400 + 323 / 240 / lightness;
    } else if (lightness <= 10 / 11) {
      chromaScale =
        (223 / 240 - (851 / 800) * lightness) / (1 - lightness);
    } else {
      chromaScale = -5 / 12;
    }
  } else {
    targetLightness =
      lightness <= 10 / 11
        ? (39 / 40) * lightness
        : (5 / 4) * lightness - 1 / 4;
    if (lightness <= 5 / 11) {
      chromaScale = 791 / 800;
    } else if (lightness <= 0.5) {
      chromaScale = 1209 / 800 - 19 / 80 / lightness;
    } else if (lightness <= 10 / 11) {
      chromaScale =
        (81 / 80 - (791 / 800) * lightness) / (1 - lightness);
    } else {
      chromaScale = 5 / 4;
    }
  }
  return source.map((component) => {
    const hueFraction = (component - minimum) / chroma;
    const provisional = targetLightness +
      chroma * chromaScale * (hueFraction - 0.5);
    const lowerBound = isBright
      ? (-5 / 12) * component
      : (5 / 4) * component - 1 / 4;
    const upperBound = isBright
      ? (17 - 5 * component) / 12
      : (5 / 4) * component;
    return Math.min(Math.max(provisional, lowerBound), upperBound);
  });
}

export function parameterizedTintMatrix(color, cell) {
  const source = [color.red, color.green, color.blue];
  if (!cell.isClear && !cell.hasMainParticipation) {
    return neutralSuppressionMatrix(cell.isLightAppearance, color.alpha);
  }
  const chroma = Math.max(...source) - Math.min(...source);
  if (chroma <= ACHROMATIC_CHROMA_THRESHOLD) {
    return achromaticMatrix(color);
  }
  const isPastel =
    !cell.isLightAppearance &&
    !cell.isClear &&
    cell.hasMainParticipation;
  if (isPastel) {
    return lumaEndpointMatrix(
      pastelEndpoint(source, true),
      pastelEndpoint(source, false),
      color.alpha
    );
  }
  return lumaEndpointMatrix(
    source,
    standardDarkEndpoint(source),
    color.alpha
  );
}

function validateRow(row, color) {
  if (
    !Array.isArray(row.matrix) ||
    row.matrix.length !== 20 ||
    !row.matrix.every(Number.isFinite)
  ) {
    throw new Error(`${row.colorID} · ${cellKey(row.cell)} has an invalid matrix`);
  }
  const source = row.sourceColor;
  const sourceResidual = maximum([
    Math.abs(source.red - color.red),
    Math.abs(source.green - color.green),
    Math.abs(source.blue - color.blue),
    Math.abs(source.alpha - color.alpha),
  ]);
  if (sourceResidual > SOURCE_TOLERANCE) {
    throw new Error(
      `${row.colorID} · ${cellKey(row.cell)} source-color residual ` +
        `${sourceResidual} exceeds ${SOURCE_TOLERANCE}`
    );
  }

  const alphaResidual = alphaRowResidual(row.matrix, color.alpha);
  if (alphaResidual > STRUCTURE_TOLERANCE) {
    throw new Error(
      `${row.colorID} · ${cellKey(row.cell)} alpha-row residual ` +
        `${alphaResidual} exceeds ${STRUCTURE_TOLERANCE}`
    );
  }

  const endpoint = lumaEndpointInfo(row.matrix);
  const neutralResidual = neutralSuppressionResidual(
    row.matrix,
    row.cell.isLightAppearance
  );
  const achromatic = achromaticChannelAffineInfo(row.matrix);
  const formulaResidual = achromaticFormulaResidual(
    row.matrix,
    color,
    alphaResidual
  );
  let family;
  let structure;
  let structureResidual;
  if (endpoint.maximumResidual <= STRUCTURE_TOLERANCE) {
    structure = "lumaEndpoints";
    const sourceRGB = [color.red, color.green, color.blue];
    const brightSourceResidual = maximumDifference(endpoint.bright, sourceRGB);
    family =
      brightSourceResidual <= STANDARD_TOLERANCE ? "standard" : "pastel";
    structureResidual = Math.max(endpoint.maximumResidual, alphaResidual);
    endpoint.brightSourceResidual = brightSourceResidual;
  } else if (neutralResidual <= STRUCTURE_TOLERANCE) {
    structure = "neutralSuppression";
    family = "neutral";
    structureResidual = Math.max(neutralResidual, alphaResidual);
  } else if (achromatic.maximumResidual <= STRUCTURE_TOLERANCE) {
    structure = "achromaticChannelAffine";
    family = "achromatic";
    structureResidual = Math.max(
      achromatic.maximumResidual,
      alphaResidual
    );
  } else {
    structure = "unclassified";
    family = "unclassified";
    structureResidual = Math.max(
      Math.min(endpoint.maximumResidual, neutralResidual),
      alphaResidual
    );
  }
  if (
    Number.isFinite(row.lumaEndpointResidual) &&
    Math.abs(row.lumaEndpointResidual - endpoint.maximumResidual) >
      STORED_RESIDUAL_TOLERANCE
  ) {
    throw new Error(
      `${row.colorID} · ${cellKey(row.cell)} stored luma residual changed`
    );
  }
  if (
    Number.isFinite(row.neutralSuppressionResidual) &&
    Math.abs(row.neutralSuppressionResidual - neutralResidual) >
      STORED_RESIDUAL_TOLERANCE
  ) {
    throw new Error(
      `${row.colorID} · ${cellKey(row.cell)} stored neutral residual changed`
    );
  }
  if (
    Number.isFinite(row.achromaticChannelAffineResidual) &&
    Math.abs(
      row.achromaticChannelAffineResidual - achromatic.maximumResidual
    ) > STORED_RESIDUAL_TOLERANCE
  ) {
    throw new Error(
      `${row.colorID} · ${cellKey(row.cell)} stored achromatic residual changed`
    );
  }
  return {
    family,
    structure,
    structureResidual,
    sourceResidual,
    endpoint,
    neutralResidual,
    achromatic,
    formulaResidual,
  };
}

export function analyzeTintParameterization(document) {
  if (document.formatVersion !== 1) {
    throw new Error(`Unsupported formatVersion ${document.formatVersion}`);
  }
  const colors = document.plan?.colors ?? [];
  const rows = document.rows ?? [];
  const colorsByID = new Map(colors.map((color) => [color.id, color]));
  if (colorsByID.size !== colors.length) {
    throw new Error("Capture plan contains duplicate color IDs");
  }

  const rowsByColor = new Map();
  const cellFamilies = new Map();
  let maximumStructureResidual = 0;
  let maximumClassifiedStructureResidual = 0;
  let maximumSourceResidual = 0;
  let maximumStandardBrightResidual = 0;
  let maximumAchromaticFormulaResidual = 0;
  let achromaticFormulaRowCount = 0;
  const parameterizationSupported =
    document.environment?.osMajorVersion === 27;
  let maximumParameterizedMatrixResidual = 0;
  let worstParameterizedRow = null;
  const unclassifiedRows = [];
  const evaluated = [];

  for (const row of rows) {
    const color = colorsByID.get(row.colorID);
    if (!color) throw new Error(`Unknown color ID ${row.colorID}`);
    const result = validateRow(row, color);
    evaluated.push({ row, color, result });
    if (parameterizationSupported) {
      const predicted = parameterizedTintMatrix(color, row.cell);
      const residual = maximumDifference(predicted, row.matrix);
      if (residual > maximumParameterizedMatrixResidual) {
        maximumParameterizedMatrixResidual = residual;
        worstParameterizedRow = {
          colorID: row.colorID,
          cell: cellKey(row.cell),
          residual,
        };
      }
    }
    maximumStructureResidual = Math.max(
      maximumStructureResidual,
      result.structureResidual
    );
    if (result.structure !== "unclassified") {
      maximumClassifiedStructureResidual = Math.max(
        maximumClassifiedStructureResidual,
        result.structureResidual
      );
    } else {
      unclassifiedRows.push({
        colorID: row.colorID,
        cell: cellKey(row.cell),
        lumaEndpointResidual: result.endpoint.maximumResidual,
        neutralSuppressionResidual: result.neutralResidual,
      });
    }
    maximumSourceResidual = Math.max(
      maximumSourceResidual,
      result.sourceResidual
    );
    if (result.family === "standard") {
      maximumStandardBrightResidual = Math.max(
        maximumStandardBrightResidual,
        result.endpoint.brightSourceResidual
      );
    }
    if (
      result.family === "achromatic" &&
      result.formulaResidual !== null
    ) {
      maximumAchromaticFormulaResidual = Math.max(
        maximumAchromaticFormulaResidual,
        result.formulaResidual
      );
      achromaticFormulaRowCount += 1;
    }
    const key = cellKey(row.cell);
    const families = cellFamilies.get(key) ?? new Map();
    families.set(result.family, (families.get(result.family) ?? 0) + 1);
    cellFamilies.set(key, families);
    const colorRows = rowsByColor.get(row.colorID) ?? [];
    colorRows.push(row);
    rowsByColor.set(row.colorID, colorRows);
  }

  const expectedCellKeys = new Set();
  for (const isLightAppearance of [true, false]) {
    for (const isClear of [false, true]) {
      for (const hasMainParticipation of [true, false]) {
        expectedCellKeys.add(
          cellKey({
            isLightAppearance,
            isClear,
            hasMainParticipation,
          })
        );
      }
    }
  }
  for (const [colorID, colorRows] of rowsByColor) {
    const actualCells = new Set(colorRows.map((row) => cellKey(row.cell)));
    if (
      colorRows.length !== 8 ||
      actualCells.size !== 8 ||
      [...expectedCellKeys].some((key) => !actualCells.has(key))
    ) {
      throw new Error(`${colorID} does not contain exactly eight unique cells`);
    }
  }

  const completedColorCount = rowsByColor.size;
  if (document.completedColorCount !== completedColorCount) {
    throw new Error(
      `completedColorCount ${document.completedColorCount} does not match ` +
        `${completedColorCount} complete color groups`
    );
  }
  if (
    document.complete &&
    (completedColorCount !== colors.length || rows.length !== colors.length * 8)
  ) {
    throw new Error("Document is marked complete but does not cover the plan");
  }

  const alphaRows = evaluated.filter(({ row }) =>
    row.colorID.startsWith("salmon-a")
  );
  const alphaByCell = Map.groupBy(alphaRows, ({ row }) => cellKey(row.cell));
  let alphaSweepMaximumNonAlphaDifference = 0;
  for (const entries of alphaByCell.values()) {
    if (entries.length < 2) continue;
    const baseline = entries[0].row.matrix;
    for (const { row } of entries.slice(1)) {
      alphaSweepMaximumNonAlphaDifference = Math.max(
        alphaSweepMaximumNonAlphaDifference,
        maximumDifference(baseline, row.matrix, new Set([18]))
      );
    }
  }
  if (alphaSweepMaximumNonAlphaDifference > ALPHA_SWEEP_TOLERANCE) {
    throw new Error(
      `Alpha sweep changed a non-a18 coefficient by ` +
        `${alphaSweepMaximumNonAlphaDifference}, exceeding ` +
        `${ALPHA_SWEEP_TOLERANCE}`
    );
  }
  if (
    parameterizationSupported &&
    maximumParameterizedMatrixResidual > PARAMETERIZED_MATRIX_TOLERANCE
  ) {
    throw new Error(
      `Parameterized matrix residual ${maximumParameterizedMatrixResidual} ` +
        `at ${worstParameterizedRow.colorID} · ` +
        `${worstParameterizedRow.cell} exceeds ` +
        `${PARAMETERIZED_MATRIX_TOLERANCE}`
    );
  }

  return {
    planID: document.plan.id,
    colorCount: colors.length,
    completedColorCount,
    rowCount: rows.length,
    complete: document.complete,
    maximumStructureResidual,
    maximumClassifiedStructureResidual,
    maximumSourceResidual,
    maximumStandardBrightResidual,
    maximumAchromaticFormulaResidual,
    achromaticFormulaRowCount,
    parameterizationSupported,
    maximumParameterizedMatrixResidual,
    worstParameterizedRow,
    alphaSweepMaximumNonAlphaDifference,
    unclassifiedRowCount: unclassifiedRows.length,
    unclassifiedRows,
    cellFamilies: Object.fromEntries(
      [...cellFamilies.entries()]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, families]) => [
          key,
          Object.fromEntries(
            [...families.entries()].sort(([left], [right]) =>
              left.localeCompare(right)
            )
          ),
        ])
    ),
  };
}

export function formatTintParameterizationReport(result) {
  const lines = [
    "== Tint Parameterization Sweep ==",
    `Plan: ${result.planID}`,
    `Coverage: ${result.completedColorCount}/${result.colorCount} colors · ` +
      `${result.rowCount} rows · ${result.complete ? "COMPLETE" : "CHECKPOINT"}`,
    `Maximum classified structure residual: ` +
      `${result.maximumClassifiedStructureResidual.toExponential(6)}`,
    `Maximum source-color residual: ${result.maximumSourceResidual.toExponential(6)}`,
    `Maximum standard bright=source residual: ` +
      `${result.maximumStandardBrightResidual.toExponential(6)}`,
    `Maximum achromatic formula residual: ` +
      `${result.maximumAchromaticFormulaResidual.toExponential(6)} ` +
      `(${result.achromaticFormulaRowCount} rows)`,
    result.parameterizationSupported
      ? `Maximum complete parameterized-matrix residual: ` +
        `${result.maximumParameterizedMatrixResidual.toExponential(6)} ` +
        `(${result.worstParameterizedRow.colorID} · ` +
        `${result.worstParameterizedRow.cell})`
      : "Complete parameterized-matrix model: NOT CERTIFIED FOR THIS MAJOR",
    `Alpha sweep maximum non-a18 difference: ` +
      `${result.alphaSweepMaximumNonAlphaDifference.toExponential(6)}`,
    `Unclassified rows: ${result.unclassifiedRowCount}`,
    "Cell transform families:",
  ];
  for (const [cell, families] of Object.entries(result.cellFamilies)) {
    const description = Object.entries(families)
      .map(([family, count]) => `${family}=${count}`)
      .join(", ");
    lines.push(`  ${cell}: ${description}`);
  }
  if (result.unclassifiedRows.length > 0) {
    lines.push("Unclassified observations:");
    for (const row of result.unclassifiedRows.slice(0, 16)) {
      lines.push(
        `  ${row.colorID} · ${row.cell}: ` +
          `luma=${row.lumaEndpointResidual.toExponential(6)}, ` +
          `neutral=${row.neutralSuppressionResidual.toExponential(6)}`
      );
    }
    if (result.unclassifiedRows.length > 16) {
      lines.push(`  … ${result.unclassifiedRows.length - 16} more`);
    }
    lines.push("Model structure coverage: REQUIRES ADDITIONAL FAMILY");
  } else {
    lines.push("Model structure coverage: ALL ROWS CLASSIFIED");
  }
  lines.push("Capture hard gates: PASSED");
  return lines.join("\n");
}

const invokedPath = process.argv[1]
  ? pathToFileURL(process.argv[1]).href
  : null;
if (invokedPath === import.meta.url) {
  const inputPath = process.argv[2];
  if (!inputPath) {
    console.error(
      "Usage: node Golden/tools/analyze-tint-parameterization.mjs " +
        "<tint-parameterization-sweep.json>"
    );
    process.exit(2);
  }
  try {
    const document = JSON.parse(await readFile(inputPath, "utf8"));
    console.log(
      formatTintParameterizationReport(
        analyzeTintParameterization(document)
      )
    );
  } catch (error) {
    console.error(`Tint parameterization analysis failed: ${error.message}`);
    process.exit(1);
  }
}
