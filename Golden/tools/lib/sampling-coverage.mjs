// Additive layer sampling on Dynamic and Semantic snapshots. Nil/absence is
// unknown; [] explicitly means the observed tree contained no backdrop layer.
export function samplingProblems(value, path = "root") {
  if (!value || typeof value !== "object") return [];
  const problems = [];
  if (Array.isArray(value.layerLines)) {
    const sampling = value.backdropSampling;
    if (!Array.isArray(sampling)) problems.push(`${path}: missing backdrop sampling evidence`);
    else for (const row of sampling) {
      if (typeof row?.path !== "string" || !Number.isFinite(row.scale) || row.scale <= 0
          || !Number.isFinite(row.marginWidth) || row.marginWidth < 0) {
        problems.push(`${path}: unreadable backdrop sampling`);
      }
    }
    const count = value.layerLines.filter(line => typeof line === "string" && line.trimStart().startsWith("CABackdropLayer")).length;
    if (Array.isArray(sampling) && (sampling.length !== count
        || new Set(sampling.map(row => row?.path)).size !== sampling.length)) {
      problems.push(`${path}: backdrop sampling coverage does not match layer tree`);
    }
  }
  for (const [key, child] of Object.entries(value)) {
    if (child && typeof child === "object") problems.push(...samplingProblems(child, `${path}.${key}`));
  }
  return problems;
}

export function comparableSampling(baseline, candidate) {
  const left = structuredClone(baseline), right = structuredClone(candidate);
  const gaps = [];
  function visit(a, b, path) {
    if (!a || !b || typeof a !== "object" || typeof b !== "object") return;
    if (Array.isArray(a.layerLines) && Array.isArray(b.layerLines)) {
      if (!Array.isArray(a.backdropSampling) || !Array.isArray(b.backdropSampling)) {
        gaps.push(path);
        delete a.backdropSampling;
        delete b.backdropSampling;
      }
    }
    for (const key of Object.keys(a)) if (key in b) visit(a[key], b[key], `${path}.${key}`);
  }
  visit(left, right, "root");
  return { baseline: left, candidate: right,
    coverage: { complete: gaps.length === 0, missingComparisons: gaps.length, examples: gaps.slice(0, 12) } };
}
