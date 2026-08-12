export const DYNAMIC_CELL_FIELDS = [
  "variant", "subvariant", "main", "key", "subdued", "appearance",
  "backdrop", "tint", "width", "height", "cornerRadius", "host", "direction",
];

export const DYNAMIC_PHASES = [
  "preflight", "trigger", "sample", "sample", "sample",
  "sample", "sample", "endpoint", "settled",
];

export const DYNAMIC_REQUESTED_PROGRESS = [
  0, 0, 0.125, 0.25, 0.5, 0.75, 0.875, 1, 1,
];

export const DYNAMIC_STABLE_PHASES = ["preflight", "settled"];
export const DYNAMIC_CONTRACT_VERSION = 2;

export function dynamicRunIdentity(run, { includeDirection = true } = {}) {
  const fields = includeDirection
    ? DYNAMIC_CELL_FIELDS
    : DYNAMIC_CELL_FIELDS.filter((field) => field !== "direction");
  return JSON.stringify([
    run?.slice ?? null,
    ...fields.map((field) => run?.cell?.[field] ?? null),
  ]);
}

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

export function stableSamplePayload(sample) {
  const projected = structuredClone(sample ?? {});
  delete projected.phase;
  delete projected.elapsed;
  delete projected.requestedProgress;
  stripRuntimeVolatileFields(projected);
  return projected;
}

export function stableEndpointSamples(run) {
  const phases = run?.slice === "core" ? ["settled"] : DYNAMIC_STABLE_PHASES;
  return (run?.samples ?? [])
    .filter(({ phase }) => phases.includes(phase))
    .map((sample) => ({ phase: sample.phase, ...stableSamplePayload(sample) }));
}

export function dynamicLifecycleProblems(run, index, side = "Dynamic") {
  const problems = [];
  const samples = run?.samples;
  if (!Array.isArray(samples) || samples.length !== DYNAMIC_PHASES.length) {
    return [`${side} run ${index} must contain ${DYNAMIC_PHASES.length} samples`];
  }
  const phases = samples.map(({ phase }) => phase);
  if (JSON.stringify(phases) !== JSON.stringify(DYNAMIC_PHASES)) {
    problems.push(`${side} run ${index} has invalid sample lifecycle ${phases.join(" → ")}`);
  }
  const requested = samples.map(({ requestedProgress }) => requestedProgress);
  if (JSON.stringify(requested) !== JSON.stringify(DYNAMIC_REQUESTED_PROGRESS)) {
    problems.push(`${side} run ${index} has invalid requested progress schedule`);
  }
  const elapsed = samples.map(({ elapsed }) => elapsed);
  if (elapsed[0] !== 0 || elapsed.some((value, sampleIndex) =>
    !Number.isFinite(value) || (sampleIndex > 0 && value < elapsed[sampleIndex - 1]))) {
    problems.push(`${side} run ${index} has invalid elapsed-time ordering`);
  }
  return problems;
}

function pairMetadata(run) {
  const metadata = structuredClone(run ?? {});
  delete metadata.samples;
  delete metadata.maximumAttachedAnimationDuration;
  if (metadata.cell) delete metadata.cell.direction;
  return metadata;
}

export function dynamicPairingProblems(runs, side = "Dynamic", {
  enforceCardinality = true,
} = {}) {
  const problems = [];
  const pairs = new Map();
  for (const [index, run] of (runs ?? []).entries()) {
    const direction = run?.cell?.direction;
    if (!["insertion", "removal"].includes(direction)) {
      problems.push(`${side} run ${index} has invalid direction ${direction}`);
      continue;
    }
    const identity = dynamicRunIdentity(run, { includeDirection: false });
    if (!pairs.has(identity)) pairs.set(identity, {});
    const pair = pairs.get(identity);
    if (pair[direction]) {
      problems.push(`${side} run ${index} duplicates its ${direction} pairing coordinate`);
    } else {
      pair[direction] = { index, run };
    }
  }
  if (enforceCardinality) {
    const counts = Object.create(null);
    for (const run of runs ?? []) {
      const key = `${run?.slice ?? "<missing>"}:${run?.cell?.direction ?? "<missing>"}`;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    const expected = {
      "core:insertion": 48, "core:removal": 48,
      "backdrop:insertion": 4, "backdrop:removal": 0,
      "repeat:insertion": 4, "repeat:removal": 0,
    };
    for (const [key, count] of Object.entries(expected)) {
      if ((counts[key] ?? 0) !== count) {
        problems.push(`${side} must contain ${count} ${key} runs; got ${counts[key] ?? 0}`);
      }
    }
  }
  for (const pair of pairs.values()) {
    if (!pair.removal) continue;
    if (!pair.insertion) {
      problems.push(`${side} removal run ${pair.removal.index} has no insertion counterpart`);
      continue;
    }
    if (JSON.stringify(pairMetadata(pair.insertion.run))
        !== JSON.stringify(pairMetadata(pair.removal.run))) {
      problems.push(
        `${side} removal run ${pair.removal.index} metadata does not match `
        + `insertion run ${pair.insertion.index}`
      );
    }
    const insertionSettled = pair.insertion.run.samples?.find(({ phase }) => phase === "settled");
    const insertionPreflight = pair.insertion.run.samples?.find(({ phase }) => phase === "preflight");
    const removalPreflight = pair.removal.run.samples?.find(({ phase }) => phase === "preflight");
    const removalSettled = pair.removal.run.samples?.find(({ phase }) => phase === "settled");
    if (insertionSettled && removalPreflight
        && JSON.stringify(stableSamplePayload(insertionSettled))
          !== JSON.stringify(stableSamplePayload(removalPreflight))) {
      problems.push(
        `${side} removal run ${pair.removal.index} preflight does not match `
        + `insertion run ${pair.insertion.index} settled endpoint`
      );
    }
    if (insertionPreflight && removalSettled
        && JSON.stringify(stableSamplePayload(insertionPreflight))
          !== JSON.stringify(stableSamplePayload(removalSettled))) {
      problems.push(
        `${side} removal run ${pair.removal.index} settled endpoint does not match `
        + `insertion run ${pair.insertion.index} preflight`
      );
    }
  }
  return problems;
}
