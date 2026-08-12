export function comparisonReportIsEquivalent(report) {
  if (typeof report?.equivalent !== "boolean") {
    throw new Error("comparison report has no schema-owned equivalent result");
  }
  return report.equivalent;
}
