import assert from "node:assert/strict";
import test from "node:test";

import {
  analyzeTintParameterization,
} from "./analyze-tint-parameterization.mjs";

const LUMA = [0.2126, 0.7152, 0.0722];

function lumaMatrix(color, bright, dark) {
  const matrix = [];
  for (let row = 0; row < 3; row += 1) {
    const scale = bright[row] - dark[row];
    matrix.push(
      scale * LUMA[0],
      scale * LUMA[1],
      scale * LUMA[2],
      0,
      dark[row]
    );
  }
  matrix.push(0, 0, 0, color.alpha, 0);
  return matrix;
}

function neutralMatrix(color, isLightAppearance) {
  const bias = isLightAppearance ? -0.1 : 0.1;
  const matrix = [];
  for (let row = 0; row < 3; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      matrix.push((row === column ? 0.7 : 0) + 0.3 * LUMA[column]);
    }
    matrix.push(0, bias);
  }
  matrix.push(0, 0, 0, color.alpha, 0);
  return matrix;
}

function makeDocument() {
  const color = {
    id: "known-coral",
    label: "Known Coral",
    red: 0.92,
    green: 0.18,
    blue: 0.38,
    alpha: 0.5,
  };
  const sourceColor = {
    red: color.red,
    green: color.green,
    blue: color.blue,
    alpha: color.alpha,
  };
  const rows = [];
  for (const isLightAppearance of [true, false]) {
    for (const isClear of [false, true]) {
      for (const hasMainParticipation of [true, false]) {
        const cell = {
          isLightAppearance,
          isClear,
          hasMainParticipation,
        };
        const standard = hasMainParticipation || isClear;
        rows.push({
          colorID: color.id,
          sourceColor,
          cell,
          matrix: standard
            ? lumaMatrix(
                color,
                [color.red, color.green, color.blue],
                [0.609, -0.027, 0.145]
              )
            : neutralMatrix(color, isLightAppearance),
          structure: standard ? "lumaEndpoints" : "neutralSuppression",
          maximumStructureResidual: 0,
        });
      }
    }
  }
  return {
    formatVersion: 1,
    capturedAt: "2026-07-29T00:00:00Z",
    operatingSystem: "test",
    environment: {
      osMajorVersion: 27,
      displaySignature: "test",
      atlasSchemaVersion: 3,
    },
    plan: {
      id: "test",
      referenceWidth: 480,
      referenceShortSide: 200,
      consecutiveStableReads: 2,
      colors: [color],
    },
    complete: true,
    completedColorCount: 1,
    rows,
    failure: null,
  };
}

function addAlphaVariant(document, alpha) {
  const baselineColor = document.plan.colors[0];
  const color = {
    ...baselineColor,
    id: `salmon-a${Math.round(alpha * 1000)}`,
    label: `Salmon ${alpha}`,
    alpha,
  };
  const rows = document.rows.map((row) => {
    const matrix = [...row.matrix];
    matrix[18] = alpha;
    return {
      ...row,
      colorID: color.id,
      sourceColor: { ...row.sourceColor, alpha },
      matrix,
    };
  });
  document.plan.colors.push(color);
  document.rows.push(...rows);
  document.completedColorCount += 1;
}

test("accepts a complete eight-cell color group", () => {
  const result = analyzeTintParameterization(makeDocument());
  assert.equal(result.complete, true);
  assert.equal(result.completedColorCount, 1);
  assert.equal(result.rowCount, 8);
  assert.ok(result.maximumStructureResidual < 1e-12);
  assert.equal(
    result.cellFamilies["Light · Regular · Main-Off"].neutral,
    1
  );
  assert.equal(
    result.cellFamilies["Dark · Clear · Main-On"].standard,
    1
  );
});

test("accepts alpha variants when only coefficient 18 changes", () => {
  const document = makeDocument();
  document.plan.colors[0].id = "salmon-a500";
  for (const row of document.rows) row.colorID = "salmon-a500";
  addAlphaVariant(document, 0.75);
  const result = analyzeTintParameterization(document);
  assert.equal(result.completedColorCount, 2);
  assert.ok(result.alphaSweepMaximumNonAlphaDifference < 1e-12);
});

test("rejects alpha variants that change an endpoint coefficient", () => {
  const document = makeDocument();
  document.plan.colors[0].id = "salmon-a500";
  for (const row of document.rows) row.colorID = "salmon-a500";
  addAlphaVariant(document, 0.75);
  const variant = document.rows.find((row) => row.colorID === "salmon-a750");
  variant.matrix[4] += 0.001;
  assert.throws(
    () => analyzeTintParameterization(document),
    /Alpha sweep changed a non-a18 coefficient/
  );
});

test("retains a structurally unfamiliar matrix as unclassified evidence", () => {
  const document = makeDocument();
  document.rows[0].matrix[0] += 0.01;
  document.rows[0].structure = "unclassified";
  const result = analyzeTintParameterization(document);
  assert.equal(result.unclassifiedRowCount, 1);
  assert.equal(
    result.cellFamilies["Light · Regular · Main-On"].unclassified,
    1
  );
});

test("rejects a row whose stored classification does not match its matrix", () => {
  const document = makeDocument();
  document.rows[0].matrix[0] += 0.01;
  assert.throws(() => analyzeTintParameterization(document), /recomputed/);
});
