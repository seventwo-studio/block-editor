import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { SwiftEditorRuntime } from "../dist/swift.js";

const output = resolve(process.argv[2] ?? ".build/modern-authoring-profile.json");
const fixture = readFileSync("benchmarks/modern-surface-1000.json");
const wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm");
const document = JSON.parse(fixture.toString());
const runtime = await SwiftEditorRuntime.initialize(wasm), call = runtime.call.bind(runtime), calls = [];
runtime.call = request => {
  const start = performance.now();
  const result = call(request);
  const ms = performance.now() - start;
  calls.push({ command: request.command, authorCommand: request.request?.command, ms, residentBytes: process.memoryUsage().rss });
  return result;
};
const sourceFiles = [...new Set(execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"]).toString().split("\0").filter(Boolean))].sort();
const sourceInputs = Object.fromEntries(sourceFiles.map(file => [file, createHash("sha256").update(readFileSync(file)).digest("hex")]));
const report = { complete: false, sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  trackedPatchSHA256: createHash("sha256").update(execFileSync("git", ["diff", "HEAD", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"])).digest("hex"),
  trackedSourceDirty: execFileSync("git", ["diff", "HEAD", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"]).length > 0,
  sourceInputs, sourceDirty: execFileSync("git", ["status", "--porcelain", "--untracked-files=all", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"]).length > 0,
  fixtureSHA256: createHash("sha256").update(fixture).digest("hex"), wasmSHA256: createHash("sha256").update(wasm).digest("hex"), calls,
  qualification: "Actual shared WASM API diagnostic including codec/memory copies; excludes browser input/rendering and does not accept surface budgets." };
mkdirSync(dirname(output), { recursive: true });
let session;
let cpu;
const cpuOutput = process.env.MODERN_CPU_PROFILE_OUTPUT;
if (cpuOutput) {
  const { Session } = await import("node:inspector"); cpu = new Session(); cpu.connect();
  await new Promise((resolve, reject) => cpu.post("Profiler.enable", error => error ? reject(error) : resolve()));
}
try {
  session = runtime.createModern({ documentID: document.documentID, actorID: "probe", epoch: "authoring-probe", document });
  const field = session.field(session.node({ blockID: "note-1", path: [] }));
  let text = document.blocks.find(block => block.id === "note-1").content[0].text;
  for (let i = 0; i < 2; i++) {
    const range = session.captureTextRange(field, text.length, text.length);
    if (cpu && i === 0) await new Promise((resolve, reject) => cpu.post("Profiler.start", error => error ? reject(error) : resolve()));
    try { assert.equal(session.execute({ command: "replaceText", target: range, arguments: { text: "!", typingGroup: "probe" } }).status, "applied"); }
    finally { if (cpu && i === 0) {
      const { profile } = await new Promise((resolve, reject) => cpu.post("Profiler.stop", (error, result) => error ? reject(error) : resolve(result)));
      const path = resolve(cpuOutput); mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, JSON.stringify(profile) + "\n");
      report.cpuProfile = { path, qualification: "V8 sampling of the first accepted append only, including shared WASM and adapter publication; instrumentation is diagnostic." };
    } }
    text += "!"; assert.equal(session.text(field), text);
    const caret = session.captureTextRange(field, text.length, text.length);
    assert.equal(session.execute({ command: "typingShortcut", target: caret, arguments: {} }).status, "noop");
    assert.equal(session.markState([caret], "bold"), "off");
  }
  report.complete = true;
} catch (error) { report.error = String(error); throw error; }
finally { cpu?.disconnect(); session?.close(); writeFileSync(output, JSON.stringify(report, null, 2) + "\n"); }
console.log(JSON.stringify(calls.filter(call => call.authorCommand || call.command === "createModern")));
