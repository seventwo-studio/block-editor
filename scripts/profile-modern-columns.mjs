import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { Session } from "node:inspector";
import { SwiftEditorRuntime } from "../dist/swift.js";

const output = resolve(process.argv[2] ?? ".build/modern-columns-profile");
mkdirSync(output, { recursive: true });
const fixture = readFileSync("benchmarks/modern-surface-1000.json"), wasm = readFileSync("dist/block-editor.wasm");
const document = JSON.parse(fixture.toString()), runtime = await SwiftEditorRuntime.initialize(wasm);
const session = runtime.createModern({ documentID: document.documentID, actorID: "resize-probe", epoch: "resize-probe", document });
const target = { layout: session.node({ blockID: "group-0-layout", path: [] }) }, cpu = new Session();
const report = { complete: false, sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  patchSHA256: createHash("sha256").update(execFileSync("git", ["diff", "HEAD"])).digest("hex"),
  fixtureSHA256: createHash("sha256").update(fixture).digest("hex"), wasmSHA256: createHash("sha256").update(wasm).digest("hex"),
  milliseconds: [], qualification: "Actual shared WASM command diagnostic; excludes native input and rendering. CPU samples cover the 23rd resize only; not surface acceptance." };
cpu.connect();
const post = (method) => new Promise((resolve, reject) => cpu.post(method, (error, result) => error ? reject(error) : resolve(result)));
try {
  await post("Profiler.enable");
  for (let i = 0; i < 23; i++) {
    const splitBasisPoints = i % 2 ? 9000 : 1000;
    if (i === 22) await post("Profiler.start");
    const start = performance.now();
    assert.equal(session.execute({ command: "resizeColumns", target, arguments: { splitBasisPoints } }).status, "applied");
    report.milliseconds.push(performance.now() - start);
    if (i === 22) writeFileSync(resolve(output, "resize.cpuprofile"), JSON.stringify((await post("Profiler.stop")).profile));
    assert.deepEqual(session.getSnapshot().document, { ...document, blocks: document.blocks.map(block => block.id === "group-0-layout" ? { ...block, splitBasisPoints } : block) });
  }
  for (let i = 0; i < 23; i++) session.execute({ command: "undo", arguments: {} });
  assert.deepEqual(session.getSnapshot().document, document);
  report.complete = true;
} finally { cpu.disconnect(); session.close(); writeFileSync(resolve(output, "receipt.json"), JSON.stringify(report, null, 2) + "\n"); }
console.log(JSON.stringify(report));
