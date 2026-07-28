// Static behaviour of all 21 Variants and 4 Subvariants, from the recursive
// layer/pass inventory.
//
// Source: Documentation/AppKitGlassReverseEngineering.md — Recipe topology.
//
// The 336-row tree has been in the archive since the first macOS 27 capture
// with no executable assertion on it; it was only ever fed to compare.mjs as
// diff material. These learnings are what pin the variant vocabulary down, and
// writing them is what surfaced the Variant 6 / Subdued interaction below.

import { cellKey } from "../tools/lib/cell.mjs";

const SECTION = "static-tree";

/** A pass identified by what it is, not where it sits in the tree. */
const family = (pass) =>
  `${pass.location.replace(/\[\d+\]/, "")}:${pass.objectClass}:${pass.name ?? "-"}`;

const inventory = (row) =>
  Object.values(row.passes ?? {}).map(family).sort().join(" | ");

/** Repeat rows are evidence about the core product, not extra product cells. */
const coreRows = (document) =>
  (document.rows ?? []).filter((row) => row.slice !== "repeat");

/** Groups rows by a subset of cell fields. */
function groupBy(rows, fields) {
  const groups = new Map();
  for (const row of rows) {
    const key = cellKey(row.cell, fields);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return groups;
}

/** Cell fields that split `rows` into more than one distinct `valueOf`. */
function splittersWithin(rows, fields, valueOf) {
  const offenders = [];
  for (const [key, members] of groupBy(rows, fields)) {
    if (new Set(members.map(valueOf)).size > 1) offenders.push(key);
  }
  return offenders;
}

export default [
  {
    id: "static-tree-covers-the-variant-product",
    claim:
      "The tree covers 21 Variants × 4 Subvariants × Main × Subdued as 336 "
      + "distinct, context-accepted cells",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = coreRows(sections[SECTION]);
      const axes = sections[SECTION].axes.values;
      expect.equal(axes.variant.length, 21, "variants swept");
      expect.equal(axes.subvariant.length, 3, "non-nil subvariants swept");
      expect.equal(axes.main.length, 2, "main values swept");
      expect.equal(axes.subdued.length, 2, "subdued values swept");
      expect.equal(rows.length, 21 * 4 * 2 * 2, "rows");
      expect.equal(
        new Set(rows.map((row) => cellKey(row.cell))).size,
        rows.length,
        "distinct cells"
      );
      expect.equal(
        rows.filter((row) => !row.accepted).length,
        0,
        "context-rejected rows"
      );
    },
  },

  {
    id: "static-tree-repeat-agrees-with-core",
    claim:
      "The repeat sweep re-captures one nil-subvariant Main-On row per Variant "
      + "and agrees with the core sweep on topology and resolved values",
    source: "Golden/CAPTURE-SPEC.md — static-tree repeat",
    sections: [SECTION],
    verify({ sections, expect }) {
      const document = sections[SECTION];
      const repeats = (document.rows ?? []).filter((row) => row.slice === "repeat");
      if (repeats.length === 0) {
        expect.unverifiable(
          "no static-tree repeat slice — capture with the direct Golden exporter"
        );
      }
      expect.equal(repeats.length, 21, "repeat rows");

      const core = new Map(coreRows(document).map((row) => [cellKey(row.cell), row]));
      const missing = [];
      const differing = [];
      for (const repeat of repeats) {
        const original = core.get(cellKey(repeat.cell));
        if (!original) {
          missing.push(cellKey(repeat.cell));
          continue;
        }
        if (original.topologySignature !== repeat.topologySignature) {
          differing.push(`${repeat.cell.variant}:topology`);
        }
        if (original.valueSignature !== repeat.valueSignature) {
          differing.push(`${repeat.cell.variant}:value`);
        }
      }
      expect.equal(missing.length, 0, "repeat cells missing from core");
      expect.equal(differing.length, 0, "repeat signature differences");
    },
  },

  {
    id: "topology-is-decided-by-variant-subvariant-and-subdued",
    claim:
      "Layer topology is a pure function of Variant, Subvariant, and Subdued. "
      + "Main never changes it: participation only moves resolved values, which "
      + "is why the strength curve can treat Main as a value axis and not a "
      + "structural one",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = coreRows(sections[SECTION]);
      const signature = (row) => row.topologySignature;

      expect.equal(
        splittersWithin(rows, ["variant", "subvariant", "subdued"], signature).length,
        0,
        "cells where those three axes fail to fix the topology"
      );

      // Main-invariance stated as its own check so a regression names the axis.
      const perMain = groupBy(rows, ["variant", "subvariant", "subdued"]);
      let compared = 0;
      const mainSensitive = [];
      for (const [key, members] of perMain) {
        if (members.length !== 2) continue;
        compared += 1;
        if (members[0].topologySignature !== members[1].topologySignature) {
          mainSensitive.push(key);
        }
      }
      expect.equal(compared, 21 * 4 * 2, "Main pairs compared");
      expect.equal(mainSensitive.length, 0, "cells whose topology follows Main");
    },
  },

  {
    id: "subdued-drops-the-gradient-branch-on-variant-6-only",
    claim:
      "Subdued is a structural axis for exactly one material. Variant 6 loses "
      + "its CASDFGradientEffect and that effect's vibrantColorMatrix when "
      + "Subdued, going 7 passes to 5; every other Variant keeps its topology",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = coreRows(sections[SECTION]);
      const sensitive = new Set();
      for (const [, members] of groupBy(rows, ["variant", "subvariant", "main"])) {
        if (new Set(members.map((row) => row.topologySignature)).size > 1) {
          sensitive.add(members[0].cell.variant);
        }
      }
      expect.equal(
        [...sensitive].sort((a, b) => a - b).join(","),
        "6",
        "variants whose topology follows Subdued"
      );

      const variantSix = rows.filter((row) => row.cell.variant === 6);
      const counts = { standard: new Set(), subdued: new Set() };
      const gradient = { standard: 0, subdued: 0 };
      for (const row of variantSix) {
        const bucket = row.cell.subdued ? "subdued" : "standard";
        counts[bucket].add(Object.keys(row.passes ?? {}).length);
        if (inventory(row).includes("CASDFGradientEffect")) gradient[bucket] += 1;
      }
      expect.equal([...counts.standard].join(","), "7", "Variant 6 standard passes");
      expect.equal([...counts.subdued].join(","), "5", "Variant 6 subdued passes");
      expect.equal(gradient.standard, 8, "standard rows carrying the gradient");
      expect.equal(gradient.subdued, 0, "subdued rows carrying the gradient");
    },
  },

  {
    id: "variants-fall-into-three-structural-classes",
    claim:
      "The 21 Variants are not one material family. Nineteen are built on a "
      + "glassBackground filter; Variant 13 renders nothing at all; Variant 14 "
      + "is built on glassForeground instead, with its own eleven-pass "
      + "inventory. A strength control that looks up a glassBackground filter "
      + "finds no baseline on 13 or 14 — those two need an explicit answer, not "
      + "a lookup failure",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = coreRows(sections[SECTION]);
      const classOf = (row) => {
        const passes = Object.values(row.passes ?? {});
        if (passes.length === 0) return "empty";
        if (passes.some((pass) => pass.name === "glassBackground")) {
          return "glassBackground";
        }
        if (passes.some((pass) => pass.name === "glassForeground")) {
          return "glassForeground";
        }
        return "unclassified";
      };

      const classes = new Map();
      for (const row of rows) {
        const name = classOf(row);
        if (!classes.has(name)) classes.set(name, new Set());
        classes.get(name).add(row.cell.variant);
      }
      const listing = (name) =>
        [...(classes.get(name) ?? [])].sort((a, b) => a - b).join(",");

      expect.equal(classes.get("unclassified")?.size ?? 0, 0, "unclassified variants");
      expect.equal(listing("empty"), "13", "variants rendering nothing");
      expect.equal(listing("glassForeground"), "14", "glassForeground variants");
      expect.equal(
        classes.get("glassBackground")?.size ?? 0,
        19,
        "glassBackground variants"
      );

      // A variant belongs to exactly one class in every cell — the class is a
      // property of the material, not of participation or subvariant.
      const perVariant = new Map();
      for (const row of rows) {
        const variant = row.cell.variant;
        if (!perVariant.has(variant)) perVariant.set(variant, new Set());
        perVariant.get(variant).add(classOf(row));
      }
      expect.equal(
        [...perVariant].filter(([, set]) => set.size > 1).length,
        0,
        "variants whose class depends on another axis"
      );
    },
  },

  {
    id: "pass-inventory-is-stable-within-a-topology",
    claim:
      "Rows sharing a topology signature share their pass inventory exactly. "
      + "The signature is therefore safe to use as a cheap cell identity when "
      + "diffing an OS capture before reading nested values",
    source: "AppKitGlassReverseEngineering.md — Recipe topology",
    sections: [SECTION],
    verify({ sections, expect }) {
      const rows = coreRows(sections[SECTION]);
      const perSignature = new Map();
      for (const row of rows) {
        const signature = row.topologySignature;
        if (!perSignature.has(signature)) perSignature.set(signature, new Set());
        perSignature.get(signature).add(inventory(row));
      }
      const inconsistent = [...perSignature].filter(([, set]) => set.size > 1);
      expect.ok(perSignature.size >= 2, "distinct topologies", `${perSignature.size}`);
      expect.equal(inconsistent.length, 0, "signatures with mixed inventories");
    },
  },
];
