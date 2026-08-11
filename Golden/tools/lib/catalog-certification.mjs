import { readFile } from "node:fs/promises";

export const REQUIRED_CATALOG_SHORT_SIDES = [48, 64, 96, 128, 160, 200, 320];

export function catalogDocumentProblems(document, expectedMajor) {
  const problems = [];
  if (document?.environment?.schemaVersion !== 2) problems.push("catalog schemaVersion must be 2");
  if (document?.environment?.osMajorVersion !== expectedMajor) {
    problems.push(`catalog environment must declare macOS ${expectedMajor}`);
  }
  if (!Array.isArray(document?.tintMatrices) || document.tintMatrices.length !== 0) {
    problems.push("certified catalog must not bundle tintMatrices");
  }
  if (!Array.isArray(document?.cells) || document.cells.length !== 16) {
    problems.push("catalog must encode exactly eight cell/sample pairs");
    return problems;
  }
  const identities = new Set();
  for (let index = 0; index < document.cells.length; index += 2) {
    const cell = document.cells[index];
    const samples = document.cells[index + 1];
    const values = [cell?.isLightAppearance, cell?.isClear, cell?.hasMainParticipation];
    if (!values.every((value) => typeof value === "boolean")) {
      problems.push(`catalog cell ${index / 2} has an invalid descriptor`);
      continue;
    }
    const identity = JSON.stringify(values);
    if (identities.has(identity)) problems.push(`catalog contains duplicate cell ${identity}`);
    identities.add(identity);
    const sides = Array.isArray(samples) ? samples.map(({ shortSide }) => shortSide) : null;
    if (JSON.stringify(sides) !== JSON.stringify(REQUIRED_CATALOG_SHORT_SIDES)) {
      problems.push(`catalog cell ${identity} has incorrect short-side coverage`);
    }
  }
  if (identities.size !== 8) problems.push(`catalog has ${identities.size} unique cell descriptors, expected 8`);
  return problems;
}

export async function validateCatalogFile(file, expectedMajor) {
  const document = JSON.parse(await readFile(file, "utf8"));
  return { document, problems: catalogDocumentProblems(document, expectedMajor) };
}

export function packageResourceProblems(packageDescription) {
  const problems = [];
  const product = packageDescription.targets?.find(({ name }) => name === "AdjustableGlass");
  if (!product) return ["AdjustableGlass target is missing"];
  const resourcePaths = (product.resources ?? []).map(({ path }) => path).sort();
  if (JSON.stringify(resourcePaths) !== JSON.stringify(["Catalog"])) {
    problems.push(`AdjustableGlass resources must be exactly Catalog; got ${resourcePaths.join(", ")}`);
  }
  if (JSON.stringify(packageDescription).includes("Golden")) {
    problems.push("Swift Package manifest output references Golden");
  }
  return problems;
}
