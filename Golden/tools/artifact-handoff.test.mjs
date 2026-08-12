import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { importArtifactEnvelope } from "./lib/artifact-handoff.mjs";

function envelope(rootKind, entries) {
  return JSON.stringify({
    schemaVersion: 1,
    rootKind,
    entries: entries.map(([entryPath, text]) => ({
      path: entryPath,
      bytes: Buffer.byteLength(text),
      data: Buffer.from(text).toString("base64"),
    })),
  });
}

test("artifact handoff reconstructs a driver directory", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-handoff-"));
  const destination = path.join(root, "artifact");
  try {
    const result = importArtifactEnvelope(envelope("directory", [
      ["capture.json", "capture"],
      ["nested/static.json", "static"],
    ]), destination);
    assert.deepEqual(result, { rootKind: "directory", entryCount: 2 });
    assert.equal(await readFile(path.join(destination, "capture.json"), "utf8"), "capture");
    assert.equal(readFileSync(path.join(destination, "nested/static.json"), "utf8"), "static");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("artifact handoff rejects paths outside the destination", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-handoff-"));
  try {
    assert.throws(
      () => importArtifactEnvelope(envelope("directory", [["../escape", "no"]]), path.join(root, "artifact")),
      /invalid artifact handoff entry/
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
