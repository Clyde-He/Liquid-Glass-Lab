import { createHash } from "node:crypto";

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonical(value[key])])
    );
  }
  return value;
}

const digest = (value) => createHash("sha256")
  .update(JSON.stringify(canonical(value)))
  .digest("hex");

function resolved(property) {
  return property?.state === "value" ? property.value ?? null : null;
}

function number(property) {
  const value = resolved(property);
  if (value?.type === "number") return value.number;
  if (value?.type === "boolean") return value.boolean ? 1 : 0;
  return null;
}

function color(property) {
  const value = resolved(property);
  return value?.type === "color" ? value.color : null;
}

function point(property) {
  const value = resolved(property);
  if (value?.type === "point") return value.point;
  if (value?.type === "size") return value.size;
  return null;
}

function auditDescription(value) {
  if (!value) return null;
  switch (value.type) {
  case "boolean": return value.boolean ? "1" : "0";
  case "number": return String(value.number);
  case "string": return value.string;
  case "color":
    return `CGColor(${value.color.model}:[${value.color.components.join(",")}])`;
  case "point": return `{${value.point.x}, ${value.point.y}}`;
  case "size": return `{${value.size.x}, ${value.size.y}}`;
  case "rect": {
    const rect = value.rect;
    return `{{${rect.x}, ${rect.y}}, {${rect.width}, ${rect.height}}}`;
  }
  case "matrix": return `ColorMatrix4x5([${value.matrix.coefficients.join(",")}])`;
  case "array": return `[${value.array.map(auditDescription).join(",")}]`;
  case "dictionary":
    return `{${Object.keys(value.dictionary).sort().map(
      (key) => `${key}:${auditDescription(value.dictionary[key])}`
    ).join(",")}}`;
  case "opaque": return `<${value.opaqueType}>`;
  default: throw new Error(`unknown resolved value type: ${value.type}`);
  }
}

function rgba(value) {
  const colorValue = value?.extendedSRGB;
  if (!colorValue) return null;
  return `rgba(${colorValue.red},${colorValue.green},${colorValue.blue},${colorValue.alpha})`;
}

function participation(cell) {
  if (cell.key === true) return "key";
  if (cell.main === true) return "main";
  return "neither";
}

export function projectStaticTree(staticDocument) {
  const rows = (staticDocument.observations ?? []).map(({ cell, snapshot }) => {
    const layers = Object.fromEntries(snapshot.layers.map((layer) => [layer.path, {
      path: layer.path,
      layerClass: layer.layerClass,
      name: layer.name ?? null,
      frame: layer.frame,
      bounds: layer.bounds,
      opacity: layer.opacity,
      isHidden: layer.isHidden,
      masksToBounds: layer.masksToBounds,
      cornerRadius: layer.cornerRadius,
      hasMask: layer.hasMask,
    }]));
    const passes = Object.fromEntries(snapshot.passes.map((pass) => [pass.id, {
      id: pass.id,
      layerPath: pass.layerPath,
      layerClass: pass.layerClass,
      location: pass.location,
      objectClass: pass.objectClass,
      name: pass.name ?? null,
      properties: Object.fromEntries(Object.entries(pass.properties).map(
        ([key, property]) => [key, {
          state: property.state,
          ...(property.state === "value"
            ? { value: auditDescription(property.value) }
            : {}),
          attributes: property.attributes ?? {},
        }]
      )),
    }]));
    const topology = {
      layers: Object.values(layers).map(({ path, layerClass, hasMask }) => ({
        path, layerClass, hasMask,
      })),
      passes: Object.values(passes).map((pass) => ({
        id: pass.id,
        keys: Object.keys(pass.properties).sort(),
      })),
    };
    return {
      cell,
      accepted: true,
      participation: participation(cell),
      topologySignature: digest(topology),
      valueSignature: digest({ layers, passes }),
      layers,
      passes,
    };
  });
  return { schemaVersion: staticDocument.schemaVersion, section: "static-tree", rows };
}

export function projectStaticScalar(staticDocument) {
  const rows = (staticDocument.observations ?? []).map(({ cell, snapshot }) => {
    const shader = snapshot.passes.find((pass) => pass.name === "glassBackground");
    const rim = snapshot.passes.find(
      (pass) => pass.objectClass === "CASDFKeyFillHighlightEffect"
    );
    const output = snapshot.passes.find(
      (pass) => pass.objectClass === "CASDFOutputEffect"
    );
    const backdrop = snapshot.layers.find(
      (layer) => layer.layerClass === "CABackdropLayer"
    );
    const inputs = {};
    const colors = {};
    const points = {};
    const strings = {};
    for (const [key, property] of Object.entries(shader?.properties ?? {})) {
      const numeric = number(property);
      const colorValue = color(property);
      const pointValue = point(property);
      const value = resolved(property);
      if (numeric !== null) inputs[key] = numeric;
      else if (colorValue) colors[key] = rgba(colorValue);
      else if (pointValue) points[key] = { x: pointValue.x, y: pointValue.y };
      else if (value?.type === "string") strings[key] = value.string;
    }

    const highlight = {};
    if (rim) {
      for (const [key, property] of Object.entries(rim.properties)) {
        const numeric = number(property);
        const colorValue = color(property);
        if (numeric !== null) highlight[key] = numeric;
        else if (colorValue) {
          colors[key] = rgba(colorValue);
          if (key === "keyColor" || key === "fillColor") {
            highlight[`${key}Alpha`] = colorValue.extendedSRGB?.alpha
              ?? colorValue.components.at(-1);
          }
        }
      }
      const owner = snapshot.layers.find((layer) => layer.path === rim.layerPath);
      if (owner) highlight.layerOpacity = owner.opacity;
    }

    const geometry = {};
    const marginWidth = number(backdrop?.properties?.marginWidth);
    const outputMinimum = number(output?.properties?.minimum);
    const outputMaximum = number(output?.properties?.maximum);
    if (marginWidth !== null) geometry.backdropMarginWidth = marginWidth;
    if (outputMinimum !== null) geometry.sdfOutputMinimum = outputMinimum;
    if (outputMaximum !== null) geometry.sdfOutputMaximum = outputMaximum;

    return {
      cell,
      accepted: true,
      participation: participation(cell),
      passes: { shader: Boolean(shader), highlight: Boolean(rim) },
      inputs,
      highlight,
      geometry,
      colors,
      points,
      strings,
    };
  });
  return { schemaVersion: staticDocument.schemaVersion, section: "static-scalar", rows };
}

const RIM_VALUE_KEYS = new Set([
  "curvature", "diffuseAmountScale", "diffuseHeightScale",
  "diffuseSpreadScale", "fillAmount", "fillAngle", "fillColorAlpha",
  "fillHeight", "fillHeightOffset", "fillHeightScale", "fillSpread",
  "fillSpreadOffset", "fillSpreadScale", "global", "keyAmount", "keyAngle",
  "keyColorAlpha", "keyHeight", "keyHeightOffset", "keyHeightScale",
  "keySpread", "keySpreadOffset", "keySpreadScale",
]);

function consumerColor(property) {
  return color(property)?.extendedSRGB ?? null;
}

/** Pure narrow runtime projection. Null means the Snapshot is not replay-safe. */
export function projectStyleSample(snapshot) {
  const shader = snapshot.passes.find((pass) => pass.name === "glassBackground");
  if (!shader) return null;
  const numeric = {};
  const colors = {};
  const points = {};
  const nilKeys = [];
  for (const [key, property] of Object.entries(shader.properties)) {
    if (property.state === "nil") {
      nilKeys.push(key);
      continue;
    }
    if (property.state !== "value") return null;
    const numericValue = number(property);
    const colorValue = consumerColor(property);
    const pointValue = point(property);
    if (numericValue !== null) numeric[key] = numericValue;
    else if (colorValue) colors[key] = colorValue;
    else if (pointValue) points[key] = [pointValue.x, pointValue.y];
    else if (resolved(property)?.type !== "string") return null;
  }
  if ((numeric.inputFaceOpacity ?? 0) < 0.999) return null;

  const tintOwners = new Set(snapshot.passes.filter(
    (pass) => pass.objectClass === "CASDFGradientEffect"
  ).map((pass) => pass.layerPath));
  const matrixPasses = snapshot.passes.filter(
    (pass) => pass.name === "vibrantColorMatrix" && !tintOwners.has(pass.layerPath)
  ).sort((lhs, rhs) => lhs.order - rhs.order);
  const matrices = [];
  for (const pass of matrixPasses) {
    const matrixValue = resolved(pass.properties.inputColorMatrix);
    if (matrixValue?.type !== "matrix") return null;
    const inputs = {};
    const nilInputKeys = [];
    for (const [key, property] of Object.entries(pass.properties)) {
      if (key === "inputColorMatrix") continue;
      if (property.state === "nil") nilInputKeys.push(key);
      else {
        const value = number(property);
        if (property.state !== "value" || value === null) return null;
        inputs[key] = value;
      }
    }
    matrices.push({
      matrix: matrixValue.matrix.coefficients.map(Math.fround),
      inputs,
      nilInputKeys: nilInputKeys.sort(),
    });
  }

  const rims = [];
  for (const pass of snapshot.passes.filter(
    (candidate) => candidate.objectClass === "CASDFKeyFillHighlightEffect"
  )) {
    const owner = snapshot.layers.find((layer) => layer.path === pass.layerPath);
    if (!owner) return null;
    const values = {};
    for (const key of RIM_VALUE_KEYS) {
      if (!Object.hasOwn(pass.properties, key)) continue;
      const value = number(pass.properties[key]);
      if (!Number.isFinite(value)) return null;
      values[key] = value;
    }
    const fillColor = consumerColor(pass.properties.fillColor);
    const keyColor = consumerColor(pass.properties.keyColor);
    if (!fillColor || !keyColor || Object.keys(values).length === 0) return null;
    rims.push({
      layerOpacity: owner.opacity,
      values,
      colors: { fillColor, keyColor },
    });
  }

  const backdrop = snapshot.layers.find(
    (layer) => layer.layerClass === "CABackdropLayer"
  );
  const output = snapshot.passes.find(
    (pass) => pass.objectClass === "CASDFOutputEffect"
  );
  const marginWidth = number(backdrop?.properties?.marginWidth);
  const outputMinimum = number(output?.properties?.minimum);
  const outputMaximum = number(output?.properties?.maximum);
  if (matrices.length !== 2 || rims.length !== 1 || marginWidth === null
      || outputMinimum === null || outputMaximum === null) return null;
  return {
    shortSide: snapshot.shortSide,
    numeric,
    colors,
    points,
    nilKeys: nilKeys.sort(),
    marginWidth,
    outputMinimum,
    outputMaximum,
    matrices,
    rims,
  };
}
