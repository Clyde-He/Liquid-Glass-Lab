#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertReportStillCurrent, assertReviewedComparisonEvidence, assertReviewedInventory,
  assertReviewedPayloadInventory, assertCleanGitState, buildBootstrapReport, repositoryRoot,
  resolveBootstrapContext,
} from "./lib/bootstrap.mjs";
import { readDispositions, releaseVerificationProblems, verifyArchiveSet } from "./lib/verify-engine.mjs";
import { sha256, validateFullDirectory } from "./lib/profile.mjs";

const args = process.argv.slice(2);
const accept = args.includes("--accept");
const candidatePath = option("--candidate");
const baselinePath = option("--baseline");
const waiver = option("--waive-baseline");
const reportPath = option("--report");

function option(name) {
  const joined = args.find((argument) => argument.startsWith(`${name}=`));
  if (joined) return joined.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : null;
}

function usage(message) {
  if (message) console.error(message);
  console.error("usage: bootstrap-new-major.mjs --candidate PATH [--baseline Golden/macOS-N | --waive-baseline REASON] [--report FILE] [--accept]");
  process.exit(64);
}

if (!candidatePath || (accept && !reportPath)) usage();
const context = await resolveBootstrapContext({ candidatePath, baselinePath, waiver });
if (!accept) {
  const report = await buildBootstrapReport(context);
  const bytes = `${JSON.stringify(report, null, 2)}\n`;
  if (reportPath) {
    const destination = path.resolve(repositoryRoot, reportPath);
    if (destination.startsWith(`${context.candidate}${path.sep}`)) {
      throw new Error("review report must be outside the candidate directory");
    }
    await writeFile(destination, bytes, { flag: "wx" });
    console.error(`Review report written to ${destination}`);
  }
  process.stdout.write(bytes);
} else {
  const reviewFile = path.resolve(repositoryRoot, reportPath);
  if (reviewFile.startsWith(`${context.candidate}${path.sep}`)) {
    throw new Error("review report must be outside the candidate directory");
  }
  const reviewBytes = await readFile(reviewFile);
  const report = JSON.parse(reviewBytes);
  await assertReportStillCurrent(report, context);
  const transactionRoot = await mkdtemp(
    path.join(path.dirname(context.target), `.${context.name}.transaction-`)
  );
  const transaction = path.join(transactionRoot, context.name);
  try {
    await cp(context.candidate, transaction, { recursive: true, force: false, errorOnExist: true });
    await assertReviewedInventory(transaction, report.candidate);
    await assertReviewedComparisonEvidence(report, context, transaction);
    const verification = await verifyArchiveSet({
      archives: context.baseline
        ? [context.baseline, { name: context.name, directory: transaction }]
        : [{ name: context.name, directory: transaction }],
      includeCrossVersion: Boolean(context.baseline),
      dispositions: await readDispositions(),
    });
    const verificationProblems = releaseVerificationProblems(verification);
    if (verificationProblems.length) {
      throw new Error(`copied transaction is not release-ready: ${verificationProblems.join("; ")}`);
    }
    const manifestPath = path.join(transaction, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.status = "accepted";
    manifest.acceptance = {
      workflow: "bootstrap-new-major", acceptedAt: new Date().toISOString(),
      sourceManifestSha256: report.candidate.manifestSha256,
      reviewReportSha256: sha256(reviewBytes),
      profileDefinitionVersion: report.profileDefinitionVersion,
      gitRevision: report.git.revision,
      baseline: report.baseline,
    };
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    const checked = await validateFullDirectory(transaction, { expectedStatus: "accepted" });
    if (checked.problems.length) throw new Error(`accepted transaction invalid: ${checked.problems.join("; ")}`);
    await assertReviewedPayloadInventory(transaction, report.candidate);
    if (JSON.stringify(assertCleanGitState()) !== JSON.stringify(report.git)) {
      throw new Error("tooling or git revision changed before atomic installation");
    }
    const helper = path.join(path.dirname(fileURLToPath(import.meta.url)), "atomic-create.swift");
    const result = spawnSync("swift", [helper, transaction, context.target], {
      cwd: repositoryRoot, encoding: "utf8",
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error((result.stderr || result.stdout).trim());
    await rm(transactionRoot, { recursive: true, force: true });
    console.log(`Accepted ${context.name} at ${context.target}; source staging was preserved.`);
  } catch (error) {
    await rm(transactionRoot, { recursive: true, force: true });
    throw error;
  }
}
