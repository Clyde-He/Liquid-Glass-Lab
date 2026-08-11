export function tintDocumentGateProblems(document, moduleID) {
  const problems = [];
  if (document.failure !== undefined && document.failure !== null) {
    problems.push(`failure=${JSON.stringify(document.failure)}`);
  }
  if (moduleID?.startsWith("tint.parameterization.")) {
    if (document.complete !== true) problems.push("complete is not true");
    const planned = document.plan?.colors?.length;
    if (!Number.isInteger(planned)) problems.push("plan.colors is missing");
    if (document.completedColorCount !== planned) {
      problems.push(`completedColorCount ${document.completedColorCount} != ${planned}`);
    }
  } else if (moduleID === "tint.sync-resolution" || moduleID === "tint.wide-gamut") {
    if (document.passed !== true) problems.push("passed is not true");
  } else if (document.passed === false || document.complete === false) {
    problems.push("document admission gate failed");
  }
  return problems;
}
