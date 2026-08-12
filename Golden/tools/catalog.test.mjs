import assert from "node:assert/strict";
import test from "node:test";
import {
  CATALOG_SHORT_SIDES, catalogBytes, catalogFromSamples, verifiesMainOn,
} from "./lib/catalog.mjs";

function sample(shortSide, main) {
  return {
    shortSide,
    numeric: {
      inputFaceOpacity: 1,
      inputShadowAmount: main ? 30 : 0,
      inputInnerRefractionAmount: main ? -30 : 0,
      inputInnerRefractionHeight: main ? 20 : 0,
    },
    colors: {}, points: {}, nilKeys: [],
    marginWidth: main ? shortSide * 0.35 : 0.5,
    outputMinimum: -10_000, outputMaximum: 1.5,
    matrices: [1, 2].map(() => ({ matrix: Array(20).fill(1), inputs: {}, nilInputKeys: [] })),
    rims: [{
      layerOpacity: main ? 1 : 0,
      values: { curvature: 0.75 },
      colors: {
        fillColor: { red: 1, green: 1, blue: 1, alpha: main ? 1 : 0 },
        keyColor: { red: 1, green: 1, blue: 1, alpha: main ? 1 : 0 },
      },
    }],
  };
}

function entries() {
  return ["Dark", "Light"].flatMap((appearance) => [1, 2].flatMap((variant) =>
    [false, true].flatMap((main) => CATALOG_SHORT_SIDES.map((shortSide) => ({
      cell: {
        variant, subvariant: null, main, key: false, subdued: false,
        appearance, backdrop: "Light", tint: "None", width: 480,
        height: shortSide, shortSide, cornerRadius: 16, host: "Panel", direction: null,
      },
      sample: sample(shortSide, main),
    })))));
}

test("Catalog is one deterministic 56-sample projection", () => {
  const document = catalogFromSamples({
    operatingSystem: "Version 27.0 (Build 26A5406e)",
    displaySignature: "Studio Display XDR @2.0x",
  }, { major: 27 }, entries());
  assert.equal(document.cells.length, 16);
  assert.deepEqual(document.tintMatrices, []);
  assert.equal(catalogBytes(document).equals(catalogBytes(document)), true);
  assert.match(catalogBytes(document).toString(), /"osMajorVersion":27/);
});

test("Catalog rejects a mislabeled Main-On payload", () => {
  assert.equal(verifiesMainOn(sample(200, false), sample(200, false)), false);
  const candidate = entries();
  candidate.find(({ cell }) => cell.main).sample = sample(48, false);
  assert.throws(() => catalogFromSamples({
    operatingSystem: "Version 27.0 (Build 26A5406e)", displaySignature: "Display",
  }, { major: 27 }, candidate), /Main-Off witness/);
});
