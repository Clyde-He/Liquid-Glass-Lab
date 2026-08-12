// The Golden cell coordinate.
//
// Every archived row — static Recipe, static recursive tree, or one run of a
// Materialize transition — is addressed by the same object. That is the whole
// point: cross-version and cross-section comparison becomes a key match instead
// of a per-fixture pairing routine written three times.
//
// A field is `null` when the capture did not control that axis. Null is not
// "false" and not "default"; it means the value is unknown, and a learning that
// needs the axis must skip rather than guess. The archived captures leave real
// holes here (static sweeps do not record appearance; the SwiftUI Materialize
// sweep has no subdued concept), and making those holes explicit is what tells
// the exporter which axes it still has to record.

/** Ordered because the key is a join; changing the order changes every key. */
export const CELL_FIELDS = [
  "variant",
  "subvariant",
  "main",
  "key",
  "subdued",
  "appearance",
  "backdrop",
  "tint",
  "width",
  "height",
  "cornerRadius",
  "host",
  "direction",
];

/** Axes both static sections control, used to pair a run with its endpoint. */
export const SHARED_FIELDS = [
  "variant",
  "subvariant",
  "main",
  "key",
  "width",
  "height",
  "cornerRadius",
  "host",
];

const token = (value) => {
  if (value === null || value === undefined) return "-";
  if (value === true) return "1";
  if (value === false) return "0";
  return String(value);
};

export function makeCell(fields = {}) {
  const cell = {};
  for (const field of CELL_FIELDS) cell[field] = fields[field] ?? null;
  // Geometry reaches the renderer only through the short side, so it is derived
  // rather than recorded — no capture can disagree with itself about it.
  cell.shortSide =
    typeof cell.width === "number" && typeof cell.height === "number"
      ? Math.min(cell.width, cell.height)
      : null;
  return cell;
}

export function cellKey(cell, fields = CELL_FIELDS) {
  return fields.map((field) => `${field}=${token(cell[field])}`).join("|");
}

/** Key over a subset of axes, for pairing rows that control different axes. */
export const sharedKey = (cell) => cellKey(cell, SHARED_FIELDS);

/**
 * True when two cells do not contradict each other on `fields`. A null on
 * either side is an uncontrolled axis and cannot contradict anything, which is
 * what lets a dynamic run (no subdued axis) pair with a static row.
 */
export function compatible(a, b, fields = CELL_FIELDS) {
  return fields.every((field) => {
    const left = a[field] ?? null;
    const right = b[field] ?? null;
    return left === null || right === null || left === right;
  });
}

/** Distinct non-null values an axis takes across rows, for coverage reports. */
export function axisValues(cells, field) {
  const values = new Set();
  for (const cell of cells) {
    if ((cell[field] ?? null) !== null) values.add(cell[field]);
  }
  return [...values].sort((a, b) =>
    typeof a === "number" && typeof b === "number"
      ? a - b
      : String(a).localeCompare(String(b))
  );
}

/** Axes a set of rows actually swept, i.e. those taking more than one value. */
export function sweptAxes(cells) {
  return CELL_FIELDS.filter((field) => axisValues(cells, field).length > 1);
}

// MARK: - Variant vocabulary
//
// The static sweeps address materials by their private variant index; the
// SwiftUI Materialize sweep only ever produced Regular and Clear and labels
// them by name. Both resolve to the same index here so the two sections share
// one axis.

export const VARIANT_REGULAR = 1;
export const VARIANT_CLEAR = 2;

export function variantFromUsage(usage) {
  const text = String(usage ?? "");
  if (text.includes("Clear")) return VARIANT_CLEAR;
  if (text.includes("Regular")) return VARIANT_REGULAR;
  return null;
}

export const isClearCell = (cell) => cell.variant === VARIANT_CLEAR;
