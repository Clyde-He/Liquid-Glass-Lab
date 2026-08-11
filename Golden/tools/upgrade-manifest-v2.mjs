#!/usr/bin/env node

import { readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { goldenDirectory, osDirectories } from "./lib/golden.mjs";
import { legacyModuleID } from "./lib/manifest.mjs";

const CLAIMS = {
  "legacy.recipe-matrix": ["legacy-recipe-product", "representative-height-response"],
  "legacy.recursive-pass-audit": ["legacy-recursive-topology", "legacy-pass-values"],
  "legacy.materialize-environment": ["legacy-materialize-environment-response"],
  "legacy.materialize-geometry": ["legacy-materialize-geometry-response"],
  "core.static-scalar": ["recipe-values", "static-axis-response"],
  "core.static-tree": ["recursive-topology", "pass-inventory", "resolved-pass-values"],
  "core.dynamic": ["transition-curve", "dynamic-axis-response", "settled-endpoints"],
  "semantic.usage-trees": ["semantic-role-topology"],
  "tint.parameterization.sweep": ["tint-transform-family", "tint-matrix-fit"],
  "tint.parameterization.focused-2b": ["tint-rgb-holdouts"],
  "tint.parameterization.hue-2c": ["tint-hue-boundary"],
  "tint.sync-resolution": ["flush-settled-tint-equivalence"],
  "tint.wide-gamut": ["display-p3-tint-model"],
  "external.window-context": ["window-context-invariance"],
  "control.recursive-display-context": ["display-context-contrast"],
  "control.recursive-stability": ["same-session-recursive-stability"],
  "research.formula-analysis": ["size-formula-envelopes"],
};

const REQUIRED = [
  "core.static-scalar", "core.static-tree", "core.dynamic",
  "tint.parameterization.sweep", "tint.parameterization.focused-2b",
  "tint.parameterization.hue-2c", "tint.sync-resolution", "tint.wide-gamut",
];

for (const osDirectory of await osDirectories()) {
  const directory = path.join(goldenDirectory, osDirectory);
  const manifestPath = path.join(directory, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const meta = JSON.parse(await readFile(path.join(directory, "unified/meta.json"), "utf8"));
  const modules = [];
  for (const fixture of manifest.fixtures ?? []) {
    const id = legacyModuleID(fixture.id);
    const bytes = (await stat(path.join(directory, fixture.file))).size;
    const carried = id === "external.window-context";
    modules.push({
      id, file: fixture.file,
      payloadSchemaVersion: fixture.schemaVersion ?? fixture.formatVersion ?? 1,
      planVersion: 1,
      platform: fixture.platform ?? manifest.platform,
      capturedAt: fixture.capturedAt ?? manifest.capturedAt,
      capture: { environment: fixture.environment ?? null, sessionID: null },
      provenance: { kind: "direct-capture", fixtureID: fixture.id },
      coverageClaims: CLAIMS[id] ?? [],
      integrity: { sha256: fixture.sha256, bytes },
      role: fixture.role ?? "canonical",
      profileStatus: REQUIRED.includes(id) || (id === "semantic.usage-trees" && osDirectory !== "macOS-26")
        ? "required" : carried ? "carried-forward" : "excluded",
    });
  }
  for (const [section, entry] of Object.entries(meta.sections)) {
    const id = `core.${section}`;
    modules.push({
      id, file: `unified/${entry.file}`,
      payloadSchemaVersion: meta.schemaVersion ?? 1,
      planVersion: 1,
      platform: manifest.unifiedPlatform ?? manifest.platform,
      capturedAt: meta.capturedAt,
      capture: { environment: null, sessionID: null },
      provenance: { kind: "direct-capture", payloadMetadata: "unified/meta.json" },
      coverageClaims: CLAIMS[id],
      integrity: { sha256: entry.sha256, bytes: entry.bytes },
      statistics: {
        rows: entry.rows,
        repeatedCells: entry.repeatedCells ?? 0,
        slices: entry.slices ?? {},
      },
      role: meta.role ?? "canonical",
      profileStatus: "required",
    });
  }
  const required = REQUIRED.filter((id) => modules.some((module) => module.id === id));
  if (modules.some((module) => module.id === "semantic.usage-trees")) required.push("semantic.usage-trees");
  const carriedForward = modules.filter((module) => module.profileStatus === "carried-forward").map((module) => module.id);
  const optional = modules.filter((module) => module.profileStatus === "optional").map((module) => module.id);
  const unsupported = osDirectory === "macOS-26" ? ["semantic.usage-trees"] : [];
  const output = {
    ...manifest,
    protocolVersion: 2,
    modules,
    profiles: { full: { required, optional, unsupported, carriedForward } },
  };
  await writeFile(manifestPath, `${JSON.stringify(output, null, 2)}\n`);
}
