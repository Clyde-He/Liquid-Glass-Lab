#!/usr/bin/env node
// Transcodes the per-study fixtures of one OS directory into the unified
// archive under `<os>/unified/`.
//
// This is a one-time bridge, not a permanent layer. Its job is to prove the
// unified schema round-trips real captures and to pin down exactly which fields
// the exporter has to emit — writing the learnings against a schema nothing has
// ever produced is how you find out too late that a field is missing.
//
//   node Golden/tools/unify.mjs macOS-26 [--dry-run]
//
// Sections written:
//   unified/static-scalar.json   resolved Recipe inputs, one row per cell
//   unified/static-tree.json     recursive layer/pass inventory, one row per cell
//   unified/dynamic.json         Materialize runs, N progress samples per cell
//   unified/meta.json            provenance and declared axes for the three

import { writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { goldenDirectory, loadModuleDocument, readManifestAt, sha256 } from "./lib/golden.mjs";
import {
  CELL_FIELDS, makeCell, cellKey, axisValues, sweptAxes, variantFromUsage,
} from "./lib/cell.mjs";

export const UNIFIED_SCHEMA_VERSION = 1;

/** `[{key, value}]` -> `{key: value}`. Halves the byte cost of every filter. */
function inputMap(inputs) {
  const map = {};
  for (const entry of inputs ?? []) map[entry.key] = entry.value;
  return map;
}

// MARK: - Static scalar, from the Recipe matrix

function unifyStaticScalar(source) {
  const environment = source.environment ?? {};
  const rows = (source.entries ?? []).map((entry) => ({
    cell: makeCell({
      variant: entry.variant,
      subvariant: entry.subvariant ?? null,
      main: entry.requestedMain,
      key: entry.isActualKeyWindow ?? null,
      subdued: entry.subdued,
      // The Recipe sweep does not control appearance: it captures whatever the
      // machine was in and records only `adaptiveAppearance` at the document
      // level. Recording null here rather than guessing "Light" is what makes
      // the endpoint-parity learning skip loudly instead of passing by luck.
      appearance: null,
      backdrop: null,
      tint: "None",
      width: entry.glassWidth,
      height: entry.glassHeight,
      cornerRadius: entry.cornerRadius,
      host: environment.hostType ?? null,
      direction: null,
    }),
    accepted: entry.appActive === true
      && entry.isActualMainWindow === entry.requestedMain
      && entry.isActualKeyWindow === false,
    participation: entry.participation ?? null,
    context: entry.context ?? null,
    passes: { shader: entry.hasShaderPass, highlight: entry.hasHighlightPass },
    inputs: entry.inputs ?? {},
    highlight: entry.highlight ?? {},
    geometry: entry.geometry ?? {},
    colors: {
      ...(entry.shaderColors ?? {}),
      ...(entry.highlightColors ?? {}),
    },
    points: entry.shaderPoints ?? {},
    strings: entry.shaderStrings ?? {},
  }));

  return {
    rows,
    // Capability lists are identical on every row; one copy is enough.
    capability: {
      shaderInputKeys: source.entries?.[0]?.shaderInputKeys ?? [],
      highlightInputKeys: source.entries?.[0]?.highlightInputKeys ?? [],
      geometryKeys: source.entries?.[0]?.geometryKeys ?? [],
    },
    environment,
  };
}

// MARK: - Static tree, from the recursive pass audit

function unifyStaticTree(source) {
  const context = source.context ?? {};
  const rows = (source.entries ?? []).map((entry) => ({
    cell: makeCell({
      variant: entry.variant,
      subvariant: entry.subvariant ?? null,
      main: entry.requestedMain,
      key: entry.isActualKeyWindow ?? null,
      subdued: entry.subdued,
      appearance: null,
      backdrop: null,
      tint: "None",
      width: entry.glassWidth ?? context.glassWidth,
      height: entry.glassHeight ?? context.glassHeight,
      cornerRadius: entry.cornerRadius ?? context.cornerRadius,
      host: context.hostType ?? null,
      direction: null,
    }),
    accepted: entry.appActive === true
      && entry.isActualMainWindow === entry.requestedMain
      && entry.isActualKeyWindow === false,
    participation: entry.participation ?? null,
    topologySignature: entry.snapshot?.topologySignature ?? null,
    valueSignature: entry.snapshot?.valueSignature ?? null,
    layers: entry.snapshot?.layers ?? {},
    passes: entry.snapshot?.passes ?? {},
  }));
  return { rows, environment: context };
}

// MARK: - Dynamic, from every Materialize sweep in the directory

/**
 * Keeps only the model-side branch of a sample. `presentation`,
 * `presentationLayers`, `modelLayers`, and `animations` are dropped: no
 * accepted learning reads them, and together they are 70% of the bytes.
 * `layerLines` stays because the SDF inflation learning parses element frames
 * out of it.
 */
function unifySample(sample) {
  const model = sample.snapshot?.model ?? {};
  const filters = (model.filters ?? []).map((filter) => ({
    name: filter.name,
    path: filter.path,
    layerClass: filter.layerClass,
    location: filter.location,
    inputs: inputMap(filter.inputs),
  }));
  const glass = filters.find((filter) => filter.name === "glassBackground");
  const face = Number(glass?.inputs?.inputFaceOpacity);
  return {
    // The observed progress, not the requested one: the renderer is the source
    // of truth for where the transition actually was when it was sampled.
    progress: Number.isFinite(face) ? face : null,
    requestedProgress: sample.requestedProgress ?? null,
    elapsed: sample.elapsed ?? null,
    phase: sample.phase ?? null,
    filters,
    effects: (model.effects ?? []).map((effect) => ({
      effectClass: effect.effectClass,
      path: effect.path,
      layerClass: effect.layerClass,
      layerOpacity: effect.layerOpacity,
      inputs: inputMap(effect.inputs),
    })),
    layerLines: model.layerLines ?? [],
  };
}

function unifyDynamic(sources) {
  const runs = [];
  for (const { id, document } of sources) {
    for (const transition of document.transitions ?? []) {
      const context = transition.context ?? {};
      runs.push({
        cell: makeCell({
          variant: variantFromUsage(transition.usage),
          subvariant: null,
          main: context.requestedMain,
          key: context.actualKey ?? null,
          // SwiftUI Materialize exposes no subdued axis, so this is genuinely
          // uncontrolled rather than false.
          subdued: null,
          appearance: context.requestedAppearance ?? null,
          backdrop: context.backdrop ?? null,
          tint: context.tint?.label ?? "None",
          width: context.glassWidth,
          height: context.glassHeight,
          cornerRadius: context.cornerRadius,
          host: context.hostType ?? null,
          direction: String(transition.direction ?? "").toLowerCase() || null,
        }),
        accepted:
          context.actualMain === context.requestedMain
          && context.actualKey === false,
        source: id,
        usage: transition.usage,
        tint: transition.context?.tint ?? null,
        effectiveAppearance: context.effectiveAppearance ?? null,
        animationMode: transition.animationMode ?? null,
        maximumAttachedAnimationDuration:
          transition.maximumAttachedAnimationDuration ?? null,
        samples: (transition.samples ?? []).map(unifySample),
      });
    }
  }
  return { runs };
}

// MARK: - Driver

function declaredAxes(cells) {
  const axes = {};
  for (const field of CELL_FIELDS) axes[field] = axisValues(cells, field);
  return { values: axes, swept: sweptAxes(cells) };
}

export async function unify(osDirectory, { dryRun = false } = {}) {
  const base = path.join(goldenDirectory, osDirectory);
  const manifest = await readManifestAt(base);
  const load = async (id) => {
    try {
      return await loadModuleDocument(base, id);
    } catch (error) {
      if (String(error.message).startsWith("Unknown Golden module")) return null;
      throw error;
    }
  };

  const sections = {};
  const provenance = {};

  const recipe = await load("legacy.recipe-matrix");
  if (recipe) {
    sections["static-scalar"] = {
      ...unifyStaticScalar(recipe.document),
      capturedAt: recipe.document.capturedAt ?? null,
      operatingSystem: recipe.document.operatingSystem ?? null,
    };
    provenance["static-scalar"] = [recipe.module.id];
  }

  const audit = await load("legacy.recursive-pass-audit");
  if (audit) {
    sections["static-tree"] = {
      ...unifyStaticTree(audit.document),
      capturedAt: audit.document.capturedAt ?? null,
      operatingSystem: audit.document.operatingSystem ?? null,
    };
    provenance["static-tree"] = [audit.module.id];
  }

  const dynamicSources = [];
  for (const id of ["legacy.materialize-environment", "legacy.materialize-geometry"]) {
    const loaded = await load(id);
    if (loaded) dynamicSources.push({ id, document: loaded.document });
  }
  if (dynamicSources.length > 0) {
    sections.dynamic = {
      ...unifyDynamic(dynamicSources),
      capturedAt: dynamicSources[0].document.capturedAt ?? null,
      operatingSystem: dynamicSources[0].document.operatingSystem ?? null,
    };
    provenance.dynamic = dynamicSources.map((source) => source.id);
  }

  const directory = path.join(base, "unified");
  if (!dryRun) await mkdir(directory, { recursive: true });

  const meta = {
    schemaVersion: UNIFIED_SCHEMA_VERSION,
    operatingSystem: manifest.operatingSystem ?? null,
    generatedFrom: provenance,
    // Transcoded, not captured. Nothing here is new evidence; the per-study
    // fixtures remain the canonical record until the exporter emits this shape
    // directly.
    role: "derived",
    sections: {},
  };

  const written = [];
  for (const [name, payload] of Object.entries(sections)) {
    const rows = payload.rows ?? payload.runs ?? [];
    const cells = rows.map((row) => row.cell);
    const document = {
      schemaVersion: UNIFIED_SCHEMA_VERSION,
      section: name,
      operatingSystem: payload.operatingSystem,
      capturedAt: payload.capturedAt,
      axes: declaredAxes(cells),
      ...payload,
    };
    const bytes = `${JSON.stringify(document)}\n`;
    const file = `${name}.json`;
    // A repeated cell is evidence, not noise: the environment and geometry
    // sweeps overlap on four cells captured in separate sessions, which is the
    // only cross-session repeatability the dynamic archive has. Deduplicating
    // would throw that away.
    const duplicates = rows.length - new Set(cells.map((c) => cellKey(c))).size;
    meta.sections[name] = {
      file,
      rows: rows.length,
      repeatedCells: duplicates,
      bytes: bytes.length,
      sha256: sha256(bytes),
      sourceFixtures: provenance[name],
      swept: document.axes.swept,
    };
    if (!dryRun) await writeFile(path.join(directory, file), bytes);
    written.push({ name, rows, bytes: bytes.length, duplicates, document });
  }

  if (!dryRun) {
    await writeFile(
      path.join(directory, "meta.json"),
      `${JSON.stringify(meta, null, 2)}\n`
    );
  }
  return { meta, written };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const targets = args.filter((arg) => !arg.startsWith("--"));
  const list = targets.length > 0 ? targets : ["macOS-26", "macOS-27"];
  for (const osDirectory of list) {
    const { meta, written } = await unify(osDirectory, { dryRun });
    console.log(`\n${osDirectory}${dryRun ? " (dry run)" : ""}`);
    for (const item of written) {
      const megabytes = (item.bytes / 1_048_576).toFixed(1);
      const duplicates = item.duplicates > 0
        ? `  ${item.duplicates} repeated cells`
        : "";
      console.log(
        `  ${item.name.padEnd(14)} ${String(item.rows.length).padStart(5)} rows`
        + `  ${megabytes.padStart(6)} MB${duplicates}`
      );
      console.log(`    swept: ${meta.sections[item.name].swept.join(", ")}`);
    }
  }
}
