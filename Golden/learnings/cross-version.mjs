// Cross-version learnings.
//
// A per-version learning answers "does this hold on this OS". These answer a
// different question: "what changed between OS versions, and does the
// abstraction in LiquidGlassLab/GlassMaterial still hold". They are the ones
// that turn a version bump into a work list instead of a re-read.
//
// They receive every loaded OS archive at once, keyed by directory name, and
// pair rows by the unified cell coordinate.

import { ALL_CHANNELS, numeric } from "../tools/lib/golden.mjs";
import { cellKey } from "../tools/lib/cell.mjs";

/** Ordered OS directories that have the given section. */
function versionsWith(archives, section) {
  return [...archives.entries()]
    .filter(([, sections]) => sections[section])
    .map(([name, sections]) => ({ name, document: sections[section] }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** Rows of a section indexed by full cell key. */
const indexByCell = (document) =>
  new Map((document.rows ?? document.runs ?? []).map((row) => [cellKey(row.cell), row]));

/** Every property name any glassBackground pass exposes in a static tree. */
function glassVocabulary(document) {
  const keys = new Set();
  for (const row of document.rows ?? []) {
    for (const pass of Object.values(row.passes ?? {})) {
      if (pass.name !== "glassBackground") continue;
      for (const key of Object.keys(pass.properties ?? {})) keys.add(key);
    }
  }
  return keys;
}

export default [
  {
    id: "cells-line-up-across-versions",
    kind: "cross-version",
    claim:
      "Both versions address the same cells. This is the precondition for "
      + "every other cross-version claim: if the coordinate does not match, a "
      + "diff is comparing different things and reports noise",
    source: "GlassResearchRoadmap.md — cross-version validation",
    verify({ archives, expect }) {
      for (const section of ["static-scalar", "static-tree"]) {
        const versions = versionsWith(archives, section);
        if (versions.length < 2) {
          expect.unverifiable(`${section} present on fewer than two versions`);
        }
        const roles = new Set(
          versions.map(({ document }) => document.archiveRole ?? "unknown")
        );
        if (roles.size > 1) {
          expect.unverifiable(
            `${section} mixes ${[...roles].join(" and ")} archives — capture `
              + "both versions directly before asserting exact cell parity"
          );
        }
        const [base, ...rest] = versions;
        const baseCells = indexByCell(base.document);
        for (const other of rest) {
          const otherCells = indexByCell(other.document);
          const onlyBase = [...baseCells.keys()].filter((k) => !otherCells.has(k));
          const onlyOther = [...otherCells.keys()].filter((k) => !baseCells.has(k));
          expect.equal(
            onlyBase.length + onlyOther.length,
            0,
            `${section}: cells unmatched between ${base.name} and ${other.name}`
          );
          expect.ok(
            baseCells.size > 0,
            `${section}: paired cells`,
            `${baseCells.size}`
          );
        }
      }
    },
  },

  {
    id: "topology-determinants-survive-the-version-bump",
    kind: "cross-version",
    claim:
      "Both versions agree that topology is fixed by Variant, Subvariant, and "
      + "Subdued, that Variant 6 is the sole Subdued-sensitive material, and "
      + "that Variant 13 renders nothing. Those three facts are what a strength "
      + "control keys its variant handling on, so a change here is a change to "
      + "the reference layer, not just to the archive",
    source: "GlassResearchRoadmap.md — cross-version validation",
    verify({ archives, expect }) {
      const versions = versionsWith(archives, "static-tree");
      if (versions.length < 2) {
        expect.unverifiable("static-tree present on fewer than two versions");
      }
      for (const { name, document } of versions) {
        const rows = document.rows ?? [];
        const groups = new Map();
        for (const row of rows) {
          const key = cellKey(row.cell, ["variant", "subvariant", "main"]);
          if (!groups.has(key)) groups.set(key, new Set());
          groups.get(key).add(row.topologySignature);
        }
        const sensitive = new Set();
        for (const [key, set] of groups) {
          if (set.size > 1) sensitive.add(Number(key.split("|")[0].split("=")[1]));
        }
        expect.equal(
          [...sensitive].sort((a, b) => a - b).join(",") || "none",
          "6",
          `${name}: Subdued-sensitive variants`
        );
        const empty = rows.filter((row) => Object.keys(row.passes ?? {}).length === 0);
        expect.equal(
          [...new Set(empty.map((row) => row.cell.variant))].join(",") || "none",
          "13",
          `${name}: variants rendering nothing`
        );
      }
    },
  },

  {
    id: "channel-table-remains-valid-but-not-complete",
    kind: "cross-version",
    claim:
      "No channel the table classifies has disappeared, so the abstraction "
      + "still resolves on the newer OS. It is not complete, though: macOS 27 "
      + "exposes 22 glassBackground inputs macOS 26 has no name for, none of "
      + "them classified. Whether that is a hole depends on whether any of them "
      + "animates, which needs a dynamic capture on 27",
    source: "GlassResearchRoadmap.md — P1.2 macOS 27 bring-up",
    verify({ archives, expect }) {
      const versions = versionsWith(archives, "static-tree");
      if (versions.length < 2) {
        expect.unverifiable("static-tree present on fewer than two versions");
      }
      const newest = versions[versions.length - 1];
      const oldest = versions[0];
      const newVocabulary = glassVocabulary(newest.document);
      const oldVocabulary = glassVocabulary(oldest.document);

      // Half one: the table still resolves. This is the half that would break
      // the shipping controller, and it must be a hard assertion.
      const vanished = ALL_CHANNELS.filter((key) => !newVocabulary.has(key));
      expect.equal(
        vanished.join(",") || "none",
        "none",
        `channels classified by the table but absent on ${newest.name}`
      );

      // Half two: report the unclassified surface rather than assert a count,
      // so a further OS adding more keys widens the report instead of failing.
      const added = [...newVocabulary].filter((key) => !oldVocabulary.has(key)).sort();
      const unclassified = added.filter((key) => !ALL_CHANNELS.includes(key));
      expect.ok(
        true,
        `inputs new on ${newest.name} versus ${oldest.name}`,
        `${added.length} added, ${unclassified.length} unclassified: `
          + `${unclassified.slice(0, 6).join(", ")}${unclassified.length > 6 ? ", …" : ""}`
      );

      const dynamicVersions = versionsWith(archives, "dynamic").map((v) => v.name);
      if (!dynamicVersions.includes(newest.name)) {
        expect.unverifiable(
          `${unclassified.length} unclassified inputs on ${newest.name} cannot be `
          + `judged: no dynamic section there. Capture one and this learning `
          + `either confirms they are static or names the channels to classify`
        );
      }
    },
  },

  {
    id: "size-scaled-inputs-are-proportional-or-inactive-never-partly",
    kind: "cross-version",
    claim:
      "For any Variant on any version, a size-scaled input is either "
      + "proportional to shortSide at every size or identically zero at every "
      + "size. Nothing is proportional at one size and zero at another. Which "
      + "Variants are inactive does move between versions — macOS 27 zeroes "
      + "shadow height on 12 of 21 Variants where macOS 26 zeroes 3 — and the "
      + "dichotomy is what makes that a non-event for a baseline-driven curve: "
      + "a zero endpoint yields a zero channel at every g without a special case",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    verify({ archives, expect }) {
      const versions = versionsWith(archives, "static-scalar");
      if (versions.length < 2) {
        expect.unverifiable("static-scalar present on fewer than two versions");
      }

      // Deliberately no universal ratio here. The 0.35 / 0.4 / 0.2 constants
      // belong to the Variant 1 family; Variant 9 resolves 0.071·S for outer
      // refraction and Variants 4, 5, and 11 are capped. Only the dichotomy is
      // shared across the whole variant vocabulary.
      const KEYS = [
        "inputBleedAmount", "inputShadowHeight", "inputOuterRefractionAmount",
      ];
      const inactivePerVersion = new Map();

      for (const { name, document } of versions) {
        const rows = (document.rows ?? []).filter(
          (row) => !row.cell.subvariant && row.cell.subdued === false && row.cell.main
        );
        const perVariant = new Map();
        for (const row of rows) {
          if (!perVariant.has(row.cell.variant)) perVariant.set(row.cell.variant, []);
          perVariant.get(row.cell.variant).push(row);
        }
        expect.requireSamples(perVariant.size, 2, `${name}: variants sampled`);

        const inactive = {};
        const partial = [];
        let examined = 0;
        for (const key of KEYS) {
          inactive[key] = [];
          for (const [variant, members] of perVariant) {
            const values = members.map((row) => numeric(row.inputs?.[key]));
            if (values.some((value) => value === null)) continue;
            examined += 1;
            const zeros = values.filter((value) => value === 0).length;
            if (zeros === values.length) inactive[key].push(variant);
            else if (zeros > 0) partial.push(`${key}@v${variant}`);
          }
        }

        expect.requireSamples(examined, 30, `${name}: variant/input pairs examined`);
        expect.equal(
          partial.join(",") || "none",
          "none",
          `${name}: inputs zero at some sizes and non-zero at others`
        );
        inactivePerVersion.set(name, inactive);
      }

      // The inactive set is reported, never asserted: it is version-specific
      // data, and pinning it here would fail on the next OS for no reason.
      for (const key of KEYS) {
        const perVersion = [...inactivePerVersion].map(
          ([name, inactive]) => `${name}=${inactive[key].length}/21`
        );
        const sets = [...inactivePerVersion.values()].map((inactive) =>
          inactive[key].join(",")
        );
        const moved = sets.some((set) => set !== sets[0]);
        expect.ok(
          true,
          `variants with ${key} inactive`,
          `${perVersion.join("  ")}${moved ? "  (changed)" : ""}`
        );
      }
    },
  },

  {
    id: "inner-refraction-ratio-moved-but-only-below-the-cap",
    kind: "cross-version",
    claim:
      "Inner refraction is the one size formula whose constant changed: -0.8·S "
      + "on macOS 26.6, -0.5·S on macOS 27.0. Both cap at the same -60, so the "
      + "difference is invisible at the 200 and 480 short sides the archive "
      + "otherwise uses. Reading endpoints from the live Recipe is what makes "
      + "this a non-event; a curve with authored constants would have shipped "
      + "the wrong refraction on one of the two versions",
    source: "GlassResearchRoadmap.md — P1.1 geometry spot check",
    verify({ archives, expect }) {
      const versions = versionsWith(archives, "static-scalar");
      if (versions.length < 2) {
        expect.unverifiable("static-scalar present on fewer than two versions");
      }
      const KEY = "inputInnerRefractionAmount";
      const perVersion = new Map();

      for (const { name, document } of versions) {
        const rows = (document.rows ?? [])
          .filter(
            (row) =>
              row.cell.variant === 1
              && row.cell.main === true
              && !row.cell.subvariant
              && row.cell.subdued === false
          )
          .sort((a, b) => a.cell.shortSide - b.cell.shortSide);
        if (rows.length < 2) continue;
        const smallest = rows[0];
        const largest = rows[rows.length - 1];
        perVersion.set(name, {
          ratio: numeric(smallest.inputs?.[KEY]) / smallest.cell.shortSide,
          cap: numeric(largest.inputs?.[KEY]),
          shortSide: smallest.cell.shortSide,
        });
      }
      expect.requireSamples(perVersion.size, 2, "versions with two sizes");

      for (const [name, { ratio, shortSide }] of perVersion) {
        expect.ok(
          Number.isFinite(ratio) && Math.abs(ratio) > 1e-6,
          `${name}: ${KEY} is proportional below the cap`,
          `${ratio.toFixed(4)}·S at shortSide ${shortSide}`
        );
      }

      // The cap is what the archive's usual sizes see, and it is the reason the
      // ratio change hid for as long as it did. It must agree across versions.
      const caps = [...perVersion.values()].map((entry) => entry.cap);
      expect.ok(
        caps.every((cap) => Math.abs(cap - caps[0]) < 1e-6),
        "the cap agrees across versions",
        [...perVersion].map(([name, e]) => `${name}=${e.cap}`).join("  ")
      );
      expect.ok(
        true,
        "ratio below the cap",
        [...perVersion]
          .map(([name, e]) => `${name}=${e.ratio.toFixed(2)}·S`)
          .join("  ")
      );
    },
  },
];
