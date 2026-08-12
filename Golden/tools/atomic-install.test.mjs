import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));

async function directory(root, name, value) {
  const result = path.join(root, name);
  await mkdir(result);
  await writeFile(path.join(result, "value"), value);
  return result;
}

function run(helper, source, target) {
  return spawnSync("xcrun", [
    "swift", path.join(toolDirectory, helper), source, target,
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: path.join(os.tmpdir(), "golden-swift-module-cache"),
    },
  });
}

test("atomic create installs once and never replaces an existing archive", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-create-"));
  try {
    const source = await directory(root, "source", "first");
    const target = path.join(root, "accepted");
    const created = run("atomic-create.swift", source, target);
    assert.equal(created.status, 0, created.stderr);
    assert.equal(await readFile(path.join(target, "value"), "utf8"), "first");
    assert.equal(existsSync(source), false);

    const second = await directory(root, "second", "second");
    assert.notEqual(run("atomic-create.swift", second, target).status, 0);
    assert.equal(await readFile(path.join(target, "value"), "utf8"), "first");
    assert.equal(await readFile(path.join(second, "value"), "utf8"), "second");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("atomic replace exposes the new archive or preserves the old one", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "golden-replace-"));
  try {
    const target = await directory(root, "accepted", "old");
    const source = await directory(root, "source", "new");
    const replaced = run("atomic-promote.swift", source, target);
    assert.equal(replaced.status, 0, replaced.stderr);
    assert.equal(await readFile(path.join(target, "value"), "utf8"), "new");
    assert.equal(existsSync(source), false);
    assert.deepEqual(
      (await readdir(root)).filter((name) => name.includes("previous")),
      []
    );

    const missing = path.join(root, "missing");
    assert.notEqual(run("atomic-promote.swift", missing, target).status, 0);
    assert.equal(await readFile(path.join(target, "value"), "utf8"), "new");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
