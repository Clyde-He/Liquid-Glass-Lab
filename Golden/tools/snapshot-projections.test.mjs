import assert from "node:assert/strict";
import test from "node:test";
import {
  projectStaticScalar, projectStaticTree, projectStyleSample,
} from "./lib/snapshot-projections.mjs";

const property = (value, state = "value") => ({
  state,
  ...(state === "value" ? { value } : {}),
  attributes: {},
});
const number = (value) => ({ type: "number", number: value });
const boolean = (value) => ({ type: "boolean", boolean: value });
const color = (red, green, blue, alpha) => ({
  type: "color",
  color: {
    colorSpaceName: "kCGColorSpaceExtendedSRGB",
    model: "rgb",
    components: [red, green, blue, alpha],
    extendedSRGB: { red, green, blue, alpha },
  },
});
const point = (x, y) => ({ type: "point", point: { x, y } });
const matrix = () => ({
  type: "matrix",
  matrix: { objCType: "{CAColorMatrix=ffffffffffffffffffff}", coefficients: Array(20).fill(1) },
});

function snapshot() {
  return {
    shortSide: 200,
    layers: [
      {
        path: "root",
        layerClass: "CALayer",
        name: null,
        frame: { x: 0, y: 0, width: 480, height: 200 },
        bounds: { x: 0, y: 0, width: 480, height: 200 },
        opacity: 1,
        isHidden: false,
        masksToBounds: false,
        cornerRadius: 0,
        hasMask: false,
        properties: {},
      },
      {
        path: "root.backdrop",
        layerClass: "CABackdropLayer",
        name: null,
        frame: { x: 0, y: 0, width: 480, height: 200 },
        bounds: { x: 0, y: 0, width: 480, height: 200 },
        opacity: 1,
        isHidden: false,
        masksToBounds: false,
        cornerRadius: 16,
        hasMask: false,
        properties: { marginWidth: property(number(70)) },
      },
      {
        path: "root.rim",
        layerClass: "CASDFLayer",
        name: null,
        frame: { x: 0, y: 0, width: 480, height: 200 },
        bounds: { x: 0, y: 0, width: 480, height: 200 },
        opacity: 0.8,
        isHidden: false,
        masksToBounds: false,
        cornerRadius: 16,
        hasMask: false,
        properties: {},
      },
    ],
    passes: [
      {
        id: "shader", order: 0, layerPath: "root.backdrop",
        layerClass: "CABackdropLayer", location: "filters",
        objectClass: "CAFilter", name: "glassBackground",
        properties: {
          inputFaceOpacity: property(number(1)),
          inputBackdropAware: property(boolean(true)),
          inputFaceColorMatrixFillColor: property(color(1, 0.5, 0.25, 0.75)),
          inputShadowOffset: property(point(0, 8)),
          inputOptional: property(null, "nil"),
        },
      },
      ...[1, 2].map((order) => ({
        id: `matrix-${order}`, order, layerPath: `root.matrix-${order}`,
        layerClass: "CALayer", location: "filters", objectClass: "CAFilter",
        name: "vibrantColorMatrix",
        properties: {
          inputColorMatrix: property(matrix()),
          inputClamp: property(number(order)),
          inputOptional: property(null, "nil"),
        },
      })),
      {
        id: "rim", order: 3, layerPath: "root.rim", layerClass: "CASDFLayer",
        location: "effect", objectClass: "CASDFKeyFillHighlightEffect", name: null,
        properties: {
          curvature: property(number(0.75)),
          fillColor: property(color(1, 1, 1, 0.5)),
          keyColor: property(color(1, 1, 1, 0.25)),
        },
      },
      {
        id: "output", order: 4, layerPath: "root.output", layerClass: "CASDFLayer",
        location: "effect", objectClass: "CASDFOutputEffect", name: null,
        properties: { minimum: property(number(-10_000)), maximum: property(number(39.8)) },
      },
    ],
  };
}

test("one Snapshot projects typed scalar and recursive research views", () => {
  const document = {
    schemaVersion: 2,
    consumerCells: [],
    observations: [{ cell: { main: true, key: false }, snapshot: snapshot() }],
  };
  const scalar = projectStaticScalar(document).rows[0];
  const tree = projectStaticTree(document).rows[0];
  assert.equal(scalar.inputs.inputBackdropAware, 1, "Bool remains a numeric shader input");
  assert.deepEqual(scalar.points.inputShadowOffset, { x: 0, y: 8 });
  assert.equal(scalar.geometry.backdropMarginWidth, 70);
  assert.equal(tree.passes.shader.properties.inputBackdropAware.value, "1");
  assert.equal(tree.passes.shader.properties.inputOptional.state, "nil");
  assert.equal(tree.layers["root.backdrop"].layerClass, "CABackdropLayer");
});

test("Consumer projection is complete, typed, and rejects unreadable critical values", () => {
  const source = snapshot();
  const sample = projectStyleSample(source);
  assert.equal(sample.matrices.length, 2);
  assert.equal(sample.rims.length, 1);
  assert.equal(sample.marginWidth, 70);
  assert.deepEqual(sample.colors.inputFaceColorMatrixFillColor, {
    red: 1, green: 0.5, blue: 0.25, alpha: 0.75,
  });
  assert.equal(
    source.passes[0].properties.inputFaceColorMatrixFillColor.value.color.colorSpaceName,
    "kCGColorSpaceExtendedSRGB",
    "the archived Snapshot retains original color-space identity"
  );

  source.passes[0].properties.inputFaceOpacity = property(null, "unreadable");
  assert.equal(projectStyleSample(source), null);
});
