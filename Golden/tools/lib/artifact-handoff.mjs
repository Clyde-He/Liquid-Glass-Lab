import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";

function safeEntryPath(file) {
  return typeof file === "string"
    && file.length > 0
    && !file.includes("\\")
    && !path.posix.isAbsolute(file)
    && path.posix.normalize(file) === file
    && file.split("/").every((component) => component !== "" && component !== "." && component !== "..");
}

function decodeEntry(entry) {
  if (!entry || !safeEntryPath(entry.path)
      || !Number.isSafeInteger(entry.bytes) || entry.bytes < 0
      || typeof entry.data !== "string") {
    throw new Error("invalid artifact handoff entry");
  }
  const bytes = Buffer.from(entry.data, "base64");
  if (bytes.length !== entry.bytes) {
    throw new Error(`artifact handoff byte count disagrees for ${entry.path}`);
  }
  return bytes;
}

export function importArtifactEnvelope(output, destination) {
  const text = Buffer.isBuffer(output) ? output.toString("utf8") : String(output ?? "");
  let envelope;
  try {
    envelope = JSON.parse(text.trim());
  } catch (error) {
    throw new Error(`driver did not return a valid artifact envelope: ${error.message}`);
  }
  if (envelope?.schemaVersion !== 1
      || !["file", "directory"].includes(envelope.rootKind)
      || !Array.isArray(envelope.entries)
      || envelope.entries.length === 0) {
    throw new Error("driver returned an invalid artifact envelope contract");
  }
  const seen = new Set();
  const entries = envelope.entries.map((entry) => {
    if (seen.has(entry?.path)) throw new Error(`duplicate artifact handoff entry: ${entry.path}`);
    seen.add(entry?.path);
    return { path: entry.path, bytes: decodeEntry(entry) };
  });
  if (envelope.rootKind === "file") {
    if (entries.length !== 1 || entries[0].path !== "artifact") {
      throw new Error("file artifact handoff must contain exactly the artifact entry");
    }
    rmSync(destination, { recursive: true, force: true });
    mkdirSync(path.dirname(destination), { recursive: true });
    writeFileSync(destination, entries[0].bytes);
  } else {
    rmSync(destination, { recursive: true, force: true });
    mkdirSync(destination, { recursive: true });
    for (const entry of entries) {
      const target = path.join(destination, ...entry.path.split("/"));
      mkdirSync(path.dirname(target), { recursive: true });
      writeFileSync(target, entry.bytes);
    }
  }
  return { rootKind: envelope.rootKind, entryCount: entries.length };
}
