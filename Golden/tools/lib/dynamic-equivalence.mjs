import {
  DYNAMIC_STABLE_PHASES, dynamicPairingProblems, dynamicRunIdentity,
  stableEndpointSamples,
} from "./dynamic-contract.mjs";

function stableProjection(runs, side, { requirePairing = true } = {}) {
  const projected = [];
  const durations = new Map();
  const problems = requirePairing
    ? [...dynamicPairingProblems(runs, side, { enforceCardinality: false })] : [];
  const identities = new Set();
  for (const [runIndex, source] of (runs ?? []).entries()) {
    const identity = dynamicRunIdentity(source);
    if (identities.has(identity)) problems.push(`${side} run ${runIndex}: duplicate identity`);
    identities.add(identity);
    durations.set(identity, source.maximumAttachedAnimationDuration);
    const run = structuredClone(source);
    delete run.maximumAttachedAnimationDuration;
    run.samples = stableEndpointSamples(run);
    const phases = run.samples.map(({ phase }) => phase);
    const expectedPhases = source?.slice === "core" ? ["settled"] : DYNAMIC_STABLE_PHASES;
    if (JSON.stringify(phases) !== JSON.stringify(expectedPhases)) {
      problems.push(
        `${side} run ${runIndex}: expected stable phases `
        + `${expectedPhases.join(", ")}; got ${phases.join(", ")}`
      );
    }
    projected.push({ identity, run });
  }
  projected.sort((lhs, rhs) => lhs.identity < rhs.identity ? -1 : lhs.identity > rhs.identity ? 1 : 0);
  return { projected: projected.map(({ run }) => run), durations, identities, problems };
}

function collectDifferences(lhs, rhs, pathName, output, outputLimit) {
  if (Object.is(lhs, rhs)) return 0;
  if (Array.isArray(lhs) || Array.isArray(rhs)) {
    if (!Array.isArray(lhs) || !Array.isArray(rhs)) {
      if (output.length < outputLimit) {
        output.push(`${pathName}: ${JSON.stringify(lhs)} != ${JSON.stringify(rhs)}`);
      }
      return 1;
    }
    let count = 0;
    const length = Math.max(lhs.length, rhs.length);
    for (let index = 0; index < length; index += 1) {
      if (index >= lhs.length || index >= rhs.length) {
        if (output.length < outputLimit) {
          output.push(`${pathName}[${index}]: ${JSON.stringify(lhs[index])} != ${JSON.stringify(rhs[index])}`);
        }
        count += 1;
      } else {
        count += collectDifferences(
          lhs[index], rhs[index], `${pathName}[${index}]`, output, outputLimit
        );
      }
    }
    return count;
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
  requireBaselinePairing = true,
  requireCandidatePairing = true,
} = {}) {
  const baseline = stableProjection(baselineRuns, "baseline", {
    requirePairing: requireBaselinePairing,
  });
  const candidate = stableProjection(candidateRuns, "candidate", {
    requirePairing: requireCandidatePairing,
  });
  const problems = [...baseline.problems, ...candidate.problems];
  const durationDeltas = [...new Set([...baseline.identities, ...candidate.identities])].map((identity) => {
    const before = baseline.durations.get(identity);
    const after = candidate.durations.get(identity);
    if (!Number.isFinite(before) || !Number.isFinite(after)) {
      problems.push(`run ${identity}: maximumAttachedAnimationDuration must be finite on both sides`);
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
    stablePhases: DYNAMIC_STABLE_PHASES,
    baselineStableSamples: baseline.projected.reduce(
      (count, run) => count + run.samples.length, 0
    ),
    candidateStableSamples: candidate.projected.reduce(
      (count, run) => count + run.samples.length, 0
    ),
    changedRuns,
    stableDifferenceCount,
    maximumAnimationDurationDelta,
    problems,
    stableDifferences,
  };
}
