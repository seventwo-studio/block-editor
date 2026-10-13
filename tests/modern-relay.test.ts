import { test, expect } from "bun:test";
import { mkdtemp, readFile, writeFile, rm, chmod } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { NativeBridge } from "../demo/relay/bridge.ts";
import { SwiftModernRecoveryError } from "../src/swift-modern.ts";
import type { ModernDocument } from "../src/swift-modern.ts";
import { modernRelayProcess } from "./helpers/modern-relay-process.ts";

const executable = resolve(process.env.BLOCK_EDITOR_BRIDGE ?? ".build/debug/editor-bridge");
const headers = { "x-local-token": "modern-relay-test", "content-type": "application/json" };
const epoch = "modern-reference-epoch";
function blank(documentID: string): ModernDocument {
  return { format: "seventwo.block-editor.document", formatVersion: 1, documentID, title: "Title",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [] };
}
function author(actor: string, documentID: string) {
  const bridge = new NativeBridge(executable);
  const call = (command: string, fields: Record<string, unknown> = {}) => bridge.call({ command, session: actor, ...fields });
  return { bridge, actor, call,
    command: (command: string, target?: unknown, args: Record<string, unknown> = {}) => call("modernCommand", { request: { documentID, epoch, command, ...(target ? { target } : {}), arguments: args } }),
    async send(endpoint: string, presenceRevision = 1) { return fetch(endpoint, { method: "POST", headers, body: JSON.stringify({ actorID: actor,
      batch: await call("modernChanges"), state: (await call("modernSnapshot")).syncState, presence: { actor, revision: presenceRevision } }) }); },
    async close() { bridge.close(); await bridge.waitForExit(); },
  };
}

test("modern relay preserves columns, concurrent title work and author Undo through real client/server process restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "modern-relay-history-"));
  const original = JSON.parse(await readFile("docs/acceptance/modern-editor/documents/columns-7000.json", "utf8")) as ModernDocument;
  const id = original.documentID, template = { document: original, epoch };
  let relay = await modernRelayProcess(directory, template), a = author("a", id); const b = author("b", id);
  const endpoint = () => `${relay.url}/rooms/${id}`;
  try {
    const baseline = await (await fetch(endpoint(), { headers })).json();
    expect(JSON.parse(await readFile(join(directory, `${id}.json`), "utf8"))).toEqual(baseline);
    for (const client of [a, b]) await client.call("restoreModern", { actorID: client.actor, snapshot: baseline });
    const title = { node: { document: { documentID: id } }, name: "title" };
    const at = (client: ReturnType<typeof author>, offset: number) => client.call("modernCaptureTextRange", { field: title, start: offset, end: offset });
    await a.command("replaceTitle", await at(a, 0), { text: "Local 😀 " });
    await b.command("replaceTitle", await at(b, original.title.length), { text: " 世界 peer" });
    const layout = { baseline: { blockID: "layout", path: [] } };
    await a.command("resizeColumns", { layout }, { splitBasisPoints: 3000 });
    await b.command("resizeColumns", { layout }, { splitBasisPoints: 6000 });
    for (const client of [a, b, a]) { const response = await client.send(endpoint()); expect(response.status).toBe(200); await client.call("modernReceive", { batch: (await response.json()).batch }); }
    const expected = structuredClone(original); (expected as { title: string }).title = "Local 😀 Field notes 世界 peer";
    (expected.blocks[0] as { splitBasisPoints: number }).splitBasisPoints = 6000;
    expect(await a.call("modernDocument")).toEqual(expected); expect(await b.call("modernDocument")).toEqual(expected);
    await a.command("undo"); expect(await a.call("modernDocument")).toEqual(expected);
    await a.command("undo"); const peerOnly = { ...expected, title: "Field notes 世界 peer" }; expect(await a.call("modernDocument")).toEqual(peerOnly);
    await a.command("redo"); expect(await a.call("modernDocument")).toEqual(expected);
    const saved = await a.call("modernSave"), outgoing = await a.call("modernChanges"), ownReceipt = (await a.call("modernSnapshot")).syncState;
    const beforeServer = await readFile(join(directory, `${id}.json`), "utf8"), oldClientPID = a.bridge.processID, oldServerPID = relay.pid;
    await a.close(); expect(() => process.kill(oldClientPID!, 0)).toThrow();
    a = author("a", id); await a.call("restoreModern", { actorID: "a", snapshot: saved });
    expect(await a.call("modernChanges")).toEqual(outgoing); expect((await a.call("modernSnapshot")).syncState).toEqual(ownReceipt);
    await relay.stop(); expect(() => process.kill(oldServerPID, 0)).toThrow(); relay = await modernRelayProcess(directory, template);
    expect(relay.pid).not.toBe(oldServerPID); expect(JSON.parse(await (await fetch(endpoint(), { headers })).text())).toEqual(JSON.parse(beforeServer));
    const response = await a.send(endpoint()); expect(response.status).toBe(200); const result = await response.json();
    expect(result.presence).toEqual([{ actor: "a", revision: 1 }]); await a.call("modernReceive", { batch: result.batch });
    expect(await a.call("modernDocument")).toEqual(expected);
    const serverSave = await readFile(join(directory, `${id}.json`), "utf8"); expect((await a.send(endpoint())).status).toBe(200);
    expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(serverSave);
  } finally { await a.close(); await b.close(); await relay.stop(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("modern identity conflict retains server bytes and the author's rejected proposal through restart and explicit repair", async () => {
  const directory = await mkdtemp(join(tmpdir(), "modern-relay-recovery-")), id = "modern-recovery";
  const document = { ...blank(id), blocks: [{ id: "root", type: "toggle", summary: [], children: [] }] };
  const template = { document, epoch }; let relay = await modernRelayProcess(directory, template), b = author("b", id); const a = author("a", id);
  const endpoint = () => `${relay.url}/rooms/${id}`;
  try {
    const baseline = await (await fetch(endpoint(), { headers })).json();
    for (const client of [a, b]) await client.call("restoreModern", { actorID: client.actor, snapshot: baseline });
    const collection = { owner: { baseline: { blockID: "root", path: [] } }, field: "children" };
    let birth;
    for (const client of [a, b]) {
      const result = await client.command("insertBlock", await client.call("modernCaptureBoundary", { collection }), { block: { id: "same", type: "paragraph", content: [{ type: "text", text: `${client.actor} 😀` }] } });
      if (client === b) birth = result.transaction;
    }
    expect((await a.send(endpoint())).status).toBe(200); const serverBefore = await readFile(join(directory, `${id}.json`), "utf8");
    const response = await b.send(endpoint()); expect(response.status).toBe(409); const failure = await response.json();
    expect(failure.error).toBe("modernRecoveryRequired"); expect(failure.state).toBeUndefined();
    expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(serverBefore);
    const originalSave = await b.call("modernSave"), originalReceipt = (await b.call("modernSnapshot")).syncState;
    await expect(b.call("modernReceive", { batch: failure.recovery.batch })).rejects.toBeInstanceOf(SwiftModernRecoveryError);
    expect(await b.call("modernSave")).toEqual(originalSave); expect((await b.call("modernSnapshot")).syncState).toEqual(originalReceipt);
    const recovery = await b.call("modernRecovery"); await b.close(); b = author("b", id);
    await b.call("restoreModern", { actorID: "b", snapshot: originalSave });
    await expect(b.call("modernRestoreRecovery", { recovery })).rejects.toBeInstanceOf(SwiftModernRecoveryError);
    expect(await b.call("modernRecovery")).toEqual(recovery); await relay.stop(); relay = await modernRelayProcess(directory, template);
    await b.call("modernRepairUndo", { targets: [birth] });
    const repaired = await b.send(endpoint()); expect(repaired.status).toBe(200); await b.call("modernReceive", { batch: (await repaired.json()).batch });
    expect(await b.call("modernRecovery")).toBeNull();
    expect(await b.call("modernDocument")).toEqual({ ...document, blocks: [{ id: "root", type: "toggle", summary: [], children: [{ id: "same", type: "paragraph", content: [{ type: "text", text: "a 😀" }] }] }] });
    const wrong = await fetch(endpoint(), { method: "POST", headers, body: JSON.stringify({ actorID: "b", batch: await b.call("modernChanges"), state: { ...originalReceipt, epoch: "wrong" } }) });
    expect(wrong.status).toBe(400); expect((await wrong.json()).state).toBeUndefined();
  } finally { await a.close(); await b.close(); await relay.stop(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("modern 8 MB boundary and oversized authored data retain pending history and receipts after process restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "modern-relay-capacity-")), id = "modern-capacity", template = { document: blank(id), epoch };
  let relay = await modernRelayProcess(directory, template), a = author("a", id); const endpoint = () => `${relay.url}/rooms/${id}`;
  try {
    const baseline = await (await fetch(endpoint(), { headers })).json(); await a.call("restoreModern", { actorID: "a", snapshot: baseline });
    const state = (await a.call("modernSnapshot")).syncState;
    const input = { actorID: "a", batch: await a.call("modernChanges"), state, padding: "" }, overhead = Buffer.byteLength(JSON.stringify(input));
    const exact = JSON.stringify({ ...input, padding: "x".repeat(8_000_000 - overhead) }); expect(Buffer.byteLength(exact)).toBe(8_000_000);
    expect((await fetch(endpoint(), { method: "POST", headers, body: exact })).status).toBe(200);
    const serverBefore = await readFile(join(directory, `${id}.json`), "utf8");
    const plusOne = JSON.stringify({ ...input, padding: "x".repeat(8_000_001 - overhead) });
    expect((await fetch(endpoint(), { method: "POST", headers, body: plusOne })).status).toBe(413);
    await a.command("insertBlock", await a.call("modernCaptureBoundary", { collection: { field: "blocks" } }), { block: { id: "large", type: "paragraph", content: [], blob: "x".repeat(8_000_000) } });
    const saved = await a.call("modernSave"), outgoing = await a.call("modernChanges"), ownReceipt = (await a.call("modernSnapshot")).syncState;
    const rejected = await a.send(endpoint()); expect(rejected.status).toBe(413); expect(await rejected.json()).toEqual({ error: "transportCapacityExceeded", maxBytes: 8_000_000 });
    expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(serverBefore); expect(await a.call("modernSave")).toEqual(saved);
    await a.close(); a = author("a", id); await a.call("restoreModern", { actorID: "a", snapshot: saved });
    await relay.stop(); relay = await modernRelayProcess(directory, template);
    expect(await a.call("modernChanges")).toEqual(outgoing); expect((await a.call("modernSnapshot")).syncState).toEqual(ownReceipt);
    expect((await a.call("modernDocument")).blocks[0].blob.length).toBe(8_000_000);
    expect((await a.send(endpoint())).status).toBe(413); expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(serverBefore);
  } finally { await a.close(); await relay.stop(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);

test("modern relay persistence failure and incompatible saved rooms reject without replacing originals or acknowledging edits", async () => {
  const directory = await mkdtemp(join(tmpdir(), "modern-relay-storage-")), id = "modern-storage", template = { document: blank(id), epoch };
  let relay = await modernRelayProcess(directory, template); const a = author("a", id), endpoint = () => `${relay.url}/rooms/${id}`;
  try {
    const baseline = await (await fetch(endpoint(), { headers })).json(); await a.call("restoreModern", { actorID: "a", snapshot: baseline });
    const before = await readFile(join(directory, `${id}.json`), "utf8");
    const field = { node: { document: { documentID: id } }, name: "title" };
    await a.command("replaceTitle", await a.call("modernCaptureTextRange", { field, start: 0, end: 0 }), { text: "Pending " });
    await chmod(directory, 0o500);
    const failed = await a.send(endpoint()); expect(failed.status).toBe(400); expect((await failed.json()).state).toBeUndefined();
    expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(before);
    expect(await (await fetch(endpoint(), { headers })).json()).toEqual(baseline);
    await chmod(directory, 0o700); expect((await a.send(endpoint())).status).toBe(200);
    const accepted = await readFile(join(directory, `${id}.json`), "utf8");
    await relay.stop(); relay = await modernRelayProcess(directory, { ...template, epoch: "new-unapproved-epoch" });
    expect((await fetch(endpoint(), { headers })).status).toBe(400); expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe(accepted);
    await relay.stop(); await writeFile(join(directory, `${id}.json`), "{original corrupted bytes"); relay = await modernRelayProcess(directory, template);
    expect((await fetch(endpoint(), { headers })).status).toBe(400); expect(await readFile(join(directory, `${id}.json`), "utf8")).toBe("{original corrupted bytes");
  } finally { await chmod(directory, 0o700); await a.close(); await relay.stop(); await rm(directory, { recursive: true, force: true }); }
}, 120_000);
