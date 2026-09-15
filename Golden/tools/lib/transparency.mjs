export function transparencyProblems(context) {
  if (context === undefined) return []; // Legacy evidence remains readable.
  const fixed = context?.control === "processOverride"
    && Number.isFinite(context.amount)
    && context.amount >= 0 && context.amount <= 1
    && context.baselineAmount === undefined;
  const canonical = context?.control === "processOverridePerObservation"
    && context.amount === undefined
    && Number.isFinite(context.baselineAmount)
    && context.baselineAmount >= 0 && context.baselineAmount <= 1;
  if (context?.version !== 1 || (!fixed && !canonical)) {
    return ["invalid transparency provenance"];
  }
  return [];
}

export function compareTransparency(baseline, candidate) {
  const left = baseline?.transparency;
  const right = candidate?.transparency;
  const valid = (value) => value !== undefined
    && transparencyProblems(value).length === 0;
  const mode = (value) => !valid(value) ? "legacy"
    : value.control === "processOverridePerObservation" ? "axis" : "fixed";
  const leftMode = mode(left), rightMode = mode(right);
  const leftAmount = leftMode === "fixed" ? left.amount
    : leftMode === "axis" ? left.baselineAmount : null;
  const rightAmount = rightMode === "fixed" ? right.amount
    : rightMode === "axis" ? right.baselineAmount : null;
  let comparable = false;
  let projectionAmount = null;
  let status = "unknown";
  if (leftMode === "legacy" && rightMode === "legacy") {
    comparable = true;
    status = "both-legacy-unmeasured";
  } else if (leftMode === "legacy" || rightMode === "legacy") {
    const measured = leftMode === "legacy" ? right : left;
    if (measured?.control === "processOverridePerObservation") {
      comparable = true;
      projectionAmount = measured.baselineAmount;
      status = "legacy-baseline-projection";
    }
  } else if (leftAmount === rightAmount) {
    comparable = true;
    projectionAmount = leftAmount;
    status = leftMode === rightMode ? "matched" : "baseline-projection";
  } else {
    status = "different";
  }
  return {
    baselineMode: leftMode,
    candidateMode: rightMode,
    baselineAmount: leftAmount,
    candidateAmount: rightAmount,
    projectionAmount,
    comparable,
    status,
  };
}
