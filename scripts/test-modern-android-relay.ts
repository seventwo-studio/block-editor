import { spawn } from "node:child_process";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { modernRelayProcess } from "../tests/helpers/modern-relay-process.ts";
import { NativeBridge } from "../demo/relay/bridge.ts";
import type { ModernDocument } from "../src/swift-modern.ts";

const args = process.argv.slice(2);
function argument(name: string, fallback?: string): string {
  const index = args.indexOf(name); const value = index >= 0 ? args[index + 1] : fallback;
  if (!value || value.startsWith("--")) throw new Error(`Missing ${name}`); return value;
}
const sdk = resolve(argument("--sdk")), serial = argument("--serial"), adbPort = argument("--adb-port", "5037");
const output = resolve(argument("--output")), apk = resolve(argument("--apk"));
await mkdir(output, { recursive: false });
const adb = join(sdk, "platform-tools/adb"), runID = randomUUID(), phonePort = 4387;
const originalBytes = await readFile("docs/acceptance/modern-editor/documents/columns-7000.json");
const document = JSON.parse(originalBytes.toString()) as ModernDocument, epoch = "modern-android-process-epoch";
async function command(parts: string[]): Promise<string> {
  const child = spawn(adb, ["-P", adbPort, "-s", serial, ...parts], { stdio: ["ignore", "pipe", "pipe"] });
  let data = ""; child.stdout.on("data", value => { data += value; }); child.stderr.on("data", value => { data += value; });
  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill(); reject(new Error("Android relay command timed out")); }, 180_000);
    child.once("error", error => { clearTimeout(timeout); reject(error); });
    child.once("exit", code => { clearTimeout(timeout); if (code === 0) resolve(data); else reject(Object.assign(new Error(`Android relay command exited ${code}`), { output: data })); });
  });
}
const serverDirectory = join(output, "server"); await mkdir(serverDirectory);
let server = await modernRelayProcess(serverDirectory, { document, epoch });
const endpoint = `http://127.0.0.1:${phonePort}/rooms/${document.documentID}`;
const bridge = new NativeBridge(resolve(process.env.BLOCK_EDITOR_BRIDGE ?? ".build/debug/editor-bridge"));
const reports: Array<{ pid: number; phase: string; passed: boolean; [key: string]: unknown }> = [];
const receipt: Record<string, unknown> = { runID, passed: false, serial, adbPort, epoch,
  fixtureSHA256: createHash("sha256").update(originalBytes).digest("hex"), source: process.env.EVIDENCE_SOURCE_SHA, phases: reports };
async function phase(name: string, authorized: boolean) {
  let log = "";
  try { log = await command(["shell", "am", "instrument", "-w", "-r", "-e", "class", "studio.seventwo.blockeditor.ModernRelayProcessTest",
    "-e", "modernRelayPhase", name, "-e", "modernRelayRun", runID, "-e", "modernRelayEndpoint", endpoint,
    ...(authorized ? ["-e", "modernRelayToken", "modern-relay-test"] : []), "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner"]); }
  catch (error) { await writeFile(join(output, `${name}-instrumentation.log`), (error as { output?: string }).output ?? String(error)); throw error; }
  await writeFile(join(output, `${name}-instrumentation.log`), log);
  if (!/OK \(1 test\)/.test(log) || /FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed/.test(log)) throw new Error(`Failed native relay phase ${name}`);
  const raw = await command(["shell", "run-as", "studio.seventwo.blockeditor.test", "cat", `files/modern-process-${runID}-${name}.json`]);
  await writeFile(join(output, `${name}-proof.json`), raw);
  const report = JSON.parse(raw); if (report.passed !== true || report.phase !== name || report.runID !== runID) throw new Error("Incomplete native relay proof");
  reports.push(report);
  await command(["shell", "am", "force-stop", "studio.seventwo.blockeditor.test"]);
  console.log(`Native Android relay phase ${name}: passed in process ${report.pid}`);
}
try {
  await command(["install", "-r", apk]);
  await command(["reverse", `tcp:${phonePort}`, `tcp:${new URL(server.url).port}`]);
  await phase("seed", true);
  const baseline = await (await fetch(`${server.url}/rooms/${document.documentID}`, { headers: { "x-local-token": "modern-relay-test" } })).json();
  const peer = "native-peer";
  await bridge.call({ command: "restoreModern", session: peer, actorID: peer, snapshot: baseline });
  for (const request of [
    { command: "setAppearance", target: { document: { documentID: document.documentID } }, arguments: { field: "fontFamily", value: "serif" } },
    { command: "resizeColumns", target: { layout: { baseline: { blockID: "layout", path: [] } } }, arguments: { splitBasisPoints: 3000 } },
  ]) {
    const result = await bridge.call({ command: "modernCommand", session: peer, request: { documentID: document.documentID, epoch, ...request } });
    if (result.status !== "applied") throw new Error(`Peer command ${request.command} was not applied`);
  }
  const response = await fetch(`${server.url}/rooms/${document.documentID}`, { method: "POST", headers: { "x-local-token": "modern-relay-test", "content-type": "application/json" },
    body: JSON.stringify({ actorID: peer, batch: await bridge.call({ command: "modernChanges", session: peer }), state: (await bridge.call({ command: "modernSnapshot", session: peer })).syncState }) });
  if (response.status !== 200) throw new Error("Peer setup did not persist");
  await server.stop(); await phase("offline", false);
  server = await modernRelayProcess(serverDirectory, { document, epoch });
  await command(["reverse", `tcp:${phonePort}`, `tcp:${new URL(server.url).port}`]);
  await phase("rejoin", true); await phase("undo", false); await phase("redo", true);
  if (new Set(reports.map(report => report.pid)).size !== 5) throw new Error("Native phases reused a process");
  const room = await readFile(join(serverDirectory, `${document.documentID}.json`));
  const fresh = "check-server"; await bridge.call({ command: "restoreModern", session: fresh, actorID: fresh, snapshot: JSON.parse(room.toString()) });
  const materialized = await bridge.call({ command: "modernDocument", session: fresh });
  if (JSON.stringify(materialized) !== JSON.stringify(reports.at(-1)?.document)) {
    const normalize = (value: unknown): unknown => Array.isArray(value) ? value.map(normalize) : value && typeof value === "object"
      ? Object.fromEntries(Object.keys(value).sort().map(key => [key, normalize((value as Record<string, unknown>)[key])])) : value;
    if (JSON.stringify(normalize(materialized)) !== JSON.stringify(normalize(reports.at(-1)?.document))) throw new Error("Persisted relay differs from the reopened native document");
  }
  receipt.passed = true; receipt.serverSHA256 = createHash("sha256").update(room).digest("hex");
} catch (error) { receipt.failure = String(error); throw error; }
finally {
  await writeFile(join(output, "receipt.json"), JSON.stringify(receipt, null, 2) + "\n");
  bridge.close(); await bridge.waitForExit(); await server.stop();
  await command(["reverse", "--remove", `tcp:${phonePort}`]);
}
