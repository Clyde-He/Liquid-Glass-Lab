const STABLE_PHASES = new Set(["settled"]);

function stripRuntimeVolatileFields(value) {
  if (!value || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) stripRuntimeVolatileFields(item);
    return;
  }
  delete value.elapsed;
  delete value.inputMaxHeadroom;
  for (const child of Object.values(value)) stripRuntimeVolatileFields(child);
}

function stableProjection(runs, side) {
  const projected = structuredClone(runs ?? []);
  const problems = [];
  for (const [runIndex, run] of projected.entries()) {
    delete run.maximumAttachedAnimationDuration;
    const stableSamples = (run.samples ?? []).filter(({ phase }) => STABLE_PHASES.has(phase));
    const phases = stableSamples.map(({ phase }) => phase);
    if (JSON.stringify(phases) !== JSON.stringify(["settled"])) {
      problems.push(`${side} run ${runIndex}: expected one settled sample; got ${phases.join(", ")}`);
    }
    run.samples = stableSamples;
    stripRuntimeVolatileFields(run);
  }
  return { projected, problems };
}

function collectDifferences(lhs, rhs, pathName, output, outputLimit) {
  if (Object.is(lhs, rhs)) return 0;
  if (Array.isArray(lhs) || Array.isArray(rhs)) {
    if (!Array.isArray(lhs) || !Array.isArray(rhs) || lhs.length !== rhs.length) {
      if (output.length < outputLimit) {
        output.push(`${pathName}: ${JSON.stringify(lhs)} != ${JSON.stringify(rhs)}`);
      }
      return 1;
    }
    return lhs.reduce(
      (count, value, index) => count + collectDifferences(
        value, rhs[index], `${pathName}[${index}]`, output, outputLimit
      ),
      0
    );
  }
  if (typeof lhs !== "object" || lhs === null || typeof rhs !== "object" || rhs === null) {
    if (output.length < outputLimit) {
      output.push(`${pathName}: ${JSON.stringify(lhs)} != ${JSON.stringify(rhs)}`);
    }
    return 1;
  }
  const keys = [...new Set([...Object.keys(lhs), ...Object.keys(rhs)])].sort();
  let count = 0;
  for (const key of keys) {
    if (!Object.hasOwn(lhs, key) || !Object.hasOwn(rhs, key)) {
      if (output.length < outputLimit) {
        output.push(`${pathName}.${key}: ${JSON.stringify(lhs[key])} != ${JSON.stringify(rhs[key])}`);
      }
      count += 1;
    } else {
      count += collectDifferences(
        lhs[key], rhs[key], `${pathName}.${key}`, output, outputLimit
      );
    }
  }
  return count;
}

export function compareStableDynamicRuns(baselineRuns, candidateRuns, {
  durationTolerance = 0.05,
  reportedDifferenceLimit = 100,
} = {}) {
  const baseline = stableProjection(baselineRuns, "baseline");
  const candidate = stableProjection(candidateRuns, "candidate");
  const problems = [...baseline.problems, ...candidate.problems];
  const durationDeltas = (baselineRuns ?? []).map((run, index) => {
    const before = run.maximumAttachedAnimationDuration;
    const after = candidateRuns?.[index]?.maximumAttachedAnimationDuration;
    if (!Number.isFinite(before) || !Number.isFinite(after)) {
      problems.push(`run ${index}: maximumAttachedAnimationDuration must be finite on both sides`);
      return Number.POSITIVE_INFINITY;
    }
    return Math.abs(before - after);
  });
  const maximumAnimationDurationDelta = Math.max(0, ...durationDeltas);
  if (maximumAnimationDurationDelta > durationTolerance) {
    problems.push(`maximum animation duration delta ${maximumAnimationDurationDelta}`);
  }

  const stableDifferences = [];
  let stableDifferenceCount = 0;
  let changedRuns = 0;
  const runCount = Math.max(baseline.projected.length, candidate.projected.length);
  for (let index = 0; index < runCount; index += 1) {
    const count = collectDifferences(
      baseline.projected[index], candidate.projected[index], `runs[${index}]`,
      stableDifferences, reportedDifferenceLimit
    );
    if (count > 0) changedRuns += 1;
    stableDifferenceCount += count;
  }
  if (stableDifferenceCount > 0) {
    problems.push(`${stableDifferenceCount} stable payload differences across ${changedRuns} runs`);
  }
  return {
    equivalent: problems.length === 0,
    baselineRuns: baselineRuns?.length ?? null,
    candidateRuns: candidateRuns?.length ?? null,
    stablePhases: [...STABLE_PHASES],
    changedRuns,
    stableDifferenceCount,
    maximumAnimationDurationDelta,
    problems,
    stableDifferences,
  };
}
