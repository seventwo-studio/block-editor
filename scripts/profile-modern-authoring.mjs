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
  calls.push({ command: request.command, authorCommand: request.request?.command, ms: performance.now() - start });
  return result;
};
const report = { complete: false, sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  trackedPatchSHA256: createHash("sha256").update(execFileSync("git", ["diff", "HEAD", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"])).digest("hex"),
  trackedSourceDirty: execFileSync("git", ["diff", "HEAD", "--", "Sources", "src", "scripts/profile-modern-authoring.mjs"]).length > 0,
  fixtureSHA256: createHash("sha256").update(fixture).digest("hex"), wasmSHA256: createHash("sha256").update(wasm).digest("hex"), calls,
  qualification: "Actual shared WASM API diagnostic including codec/memory copies; excludes browser input/rendering and does not accept surface budgets." };
mkdirSync(dirname(output), { recursive: true });
let session;
try {
  session = runtime.createModern({ documentID: document.documentID, actorID: "probe", epoch: "authoring-probe", document });
  const field = session.field(session.node({ blockID: "note-1", path: [] }));
  let text = document.blocks.find(block => block.id === "note-1").content[0].text;
  for (let i = 0; i < 2; i++) {
    const range = session.captureTextRange(field, text.length, text.length);
    assert.equal(session.execute({ command: "replaceText", target: range, arguments: { text: "!", typingGroup: "probe" } }).status, "applied");
    text += "!"; assert.equal(session.text(field), text);
    const caret = session.captureTextRange(field, text.length, text.length);
    assert.equal(session.execute({ command: "typingShortcut", target: caret, arguments: {} }).status, "noop");
    assert.equal(session.markState([caret], "bold"), "off");
  }
  report.complete = true;
} catch (error) { report.error = String(error); throw error; }
finally { session?.close(); writeFileSync(output, JSON.stringify(report, null, 2) + "\n"); }
console.log(JSON.stringify(calls.filter(call => call.authorCommand || call.command === "createModern")));
