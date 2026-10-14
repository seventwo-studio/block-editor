import { test, expect, chromium, webkit, firefox, type Page } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { NativeBridge } from "../demo/relay/bridge.ts";
import { processLab, executable, headers, token } from "./helpers/relay-process.ts";
import type { ModernBrowserCheckpoint } from "../src/swift-modern-host.ts";
import type { ModernDocument } from "../src/swift-modern.ts";

const epoch = "modern-reference-epoch";
const blank = (documentID: string): ModernDocument => ({ format: "seventwo.block-editor.document", formatVersion: 1, documentID, title: "Title",
  appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [] });
async function checkpoint(page: Page, key: string): Promise<ModernBrowserCheckpoint> {
  return page.evaluate(async key => {
    const db = await new Promise<IDBDatabase>((resolve, reject) => { const request = indexedDB.open("modern-local-relay", 1); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); });
    try { return await new Promise<ModernBrowserCheckpoint>((resolve, reject) => { const request = db.transaction("pairs").objectStore("pairs").get(key); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); }); }
    finally { db.close(); }
  }, key);
}
async function seed(page: Page, value: ModernBrowserCheckpoint): Promise<void> {
  await page.evaluate(async ({ root, valueJSON }) => {
    const { ModernBrowserStore } = await import(/* @vite-ignore */ `${root}/src/swift-modern-host.ts`);
    const pair = JSON.parse(valueJSON); await new ModernBrowserStore("modern-local-relay").save(`${pair.documentID}:${pair.actorID}`, pair);
  }, { root: `/block-editor/@fs${process.cwd()}`, valueJSON: JSON.stringify(value) });
}
async function open(page: Page, room: string, actor: string, credential = token) {
  await page.goto("modern-relay.html"); await page.getByLabel("Room", { exact: true }).fill(room);
  await page.getByLabel("Author ID").fill(actor); if (credential) await page.getByLabel("Local demo token").fill(credential);
  await page.getByRole("button", { name: "Open editor", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toBeVisible();
}
async function nativePair(bridge: NativeBridge, room: string, actor: string): Promise<ModernBrowserCheckpoint> {
  const call = (command: string) => bridge.call({ command, session: actor });
  return { version: 1, revision: crypto.randomUUID(), documentID: room, actorID: actor, epoch,
    accepted: await call("modernSave"), historySelection: await call("modernExportHistorySelection"), providers: await call("modernExportAsyncRequests"),
    recovery: await call("modernRecovery"), deferred: [], inputs: [], clipboard: [], relay: { key: "local-modern-reference", receipt: { version: 7, documentID: room, epoch, received: [] } } };
}

test("modern browser input survives offline browser/server process restart, rejoin and author Undo", async ({ browserName }, info) => {
  const lab = await processLab({ chromium, webkit, firefox }[browserName], info), peer = new NativeBridge(executable);
  const room = "modern-browser-history", actor = "browser-author";
  const fixture = JSON.parse(await readFile("docs/acceptance/modern-editor/documents/columns-7000.json", "utf8")) as ModernDocument;
  const template = { document: fixture, epoch }, call = (command: string, fields: Record<string, unknown> = {}) => peer.call({ command, session: "peer", ...fields });
  try {
    await lab.startServer(undefined, 1, template); let context = await lab.launch(), page = await context.newPage(); await open(page, room, actor);
    await page.getByLabel("Connected to local relay").uncheck();
    await page.getByRole("textbox", { name: "Document title", exact: true }).fill("Offline 😀 author");
    await expect(page.getByRole("status", { name: "Synchronization status" })).toContainText("1 unacknowledged");
    await page.getByRole("button", { name: "Save locally", exact: true }).click();
    await expect(page.getByRole("status", { name: "Local save status" })).toHaveText("Local checkpoint saved");
    const local = await checkpoint(page, `${room}:${actor}`), beforeRequests = lab.requests;
    const baseline = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json(); await call("restoreModern", { actorID: "peer", snapshot: baseline });
    await call("modernCommand", { request: { documentID: room, epoch, command: "setAppearance", target: { document: { documentID: room } }, arguments: { field: "fontFamily", value: "serif" } } });
    await call("modernCommand", { request: { documentID: room, epoch, command: "resizeColumns", target: { layout: { baseline: { blockID: "layout", path: [] } } }, arguments: { splitBasisPoints: 3000 } } });
    const response = await fetch(`${lab.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({ actorID: "peer", batch: await call("modernChanges"), state: (await call("modernSnapshot")).syncState, presence: { actor: "peer", revision: 1 } }) });
    expect(response.status).toBe(200); const serverBefore = await lab.savedRoom(room);
    await lab.closeBrowser(); await lab.stopServer(); await lab.startServer(undefined, 1, template);
    expect(await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json()).toEqual(JSON.parse(serverBefore));
    context = await lab.launch(); page = await context.newPage(); await open(page, room, actor, "");
    await expect(page.getByRole("status", { name: "Synchronization status" })).toContainText("Offline; 1 unacknowledged");
    await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toHaveText("Offline 😀 author");
    expect((await checkpoint(page, `${room}:${actor}`)).accepted).toEqual(local.accepted); expect(lab.requests).toBe(beforeRequests);
    await page.getByLabel("Local demo token").fill(token); await page.getByLabel("Connected to local relay").check();
    await page.getByRole("button", { name: "Synchronize", exact: true }).click();
    await expect(page.getByRole("status", { name: "Synchronization status" })).toHaveText("Connected; 0 unacknowledged changes; 0 peers");
    await expect(page.getByRole("slider", { name: "Column split" })).toHaveValue("3000");
    await page.getByRole("button", { name: "Undo", exact: true }).click();
    await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toHaveText(fixture.title);
    await expect(page.getByRole("slider", { name: "Column split" })).toHaveValue("3000");
    await page.getByText("More", { exact: true }).click(); await page.getByRole("button", { name: "Redo", exact: true }).click();
    await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toHaveText("Offline 😀 author");
    await page.getByRole("button", { name: "Save locally", exact: true }).click(); await expect(page.getByRole("status", { name: "Local save status" })).toHaveText("Local checkpoint saved");
    const paired = await checkpoint(page, `${room}:${actor}`);
    await call("restoreModern", { actorID: actor, snapshot: paired.accepted, session: "verify" });
    const actual = await peer.call({ command: "modernDocument", session: "verify" });
    const expected = structuredClone(fixture); (expected as { documentID: string }).documentID = room; (expected as { title: string }).title = "Offline 😀 author";
    (expected.appearance as { fontFamily: string }).fontFamily = "serif"; (expected.blocks[0] as { splitBasisPoints: number }).splitBasisPoints = 3000;
    expect(actual).toEqual(expected);
    lab.phases.push({ phase: "modern-restart-rejoin", protocol: 7, pairedOriginalHistory: true, actualBrowserAndServerProcesses: true, peerSplitAndAppearanceRetained: true, originalDocumentPreserved: true });
    await page.screenshot({ path: info.outputPath("modern-relay-rejoined.png"), fullPage: true });
  } finally { peer.close(); await peer.waitForExit(); try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); } finally { await lab.cleanup(); } }
});

test("modern rejected recovery reopens with original accepted input before explicit author repair", async ({ browserName }, info) => {
  const lab = await processLab({ chromium, webkit, firefox }[browserName], info), peer = new NativeBridge(executable);
  const room = "modern-browser-recovery", actor = "browser-author", document = { ...blank(room), blocks: [{ id: "root", type: "toggle", summary: [], children: [] }] };
  const template = { document, epoch }, call = (session: string, command: string, fields: Record<string, unknown> = {}) => peer.call({ session, command, ...fields });
  try {
    await lab.startServer(undefined, 1, template); const baseline = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json();
    for (const owner of ["peer", actor]) {
      await call(owner, "restoreModern", { actorID: owner, snapshot: baseline });
      const boundary = await call(owner, "modernCaptureBoundary", { collection: { owner: { baseline: { blockID: "root", path: [] } }, field: "children" } });
      await call(owner, "modernCommand", { request: { documentID: room, epoch, command: "insertBlock", target: boundary, arguments: { block: { id: "same", type: "paragraph", content: [{ type: "text", text: `${owner} 😀` }] } } } });
    }
    const accepted = await fetch(`${lab.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({ actorID: "peer", batch: await call("peer", "modernChanges"), state: (await call("peer", "modernSnapshot")).syncState }) }); expect(accepted.status).toBe(200);
    const serverBefore = await lab.savedRoom(room), pair = await nativePair(peer, room, actor);
    let context = await lab.launch(), page = await context.newPage(); await page.goto("modern-relay.html"); await seed(page, pair); await open(page, room, actor);
    await page.getByRole("button", { name: "Synchronize", exact: true }).click();
    await expect(page.getByRole("button", { name: "Undo my rejected changes", exact: true })).toBeVisible();
    const retained = await checkpoint(page, `${room}:${actor}`); expect(retained.accepted).toEqual(pair.accepted); expect(retained.relay?.receipt).toEqual(pair.relay?.receipt);
    expect(retained.recovery).not.toBeNull(); expect(await lab.savedRoom(room)).toBe(serverBefore);
    await lab.closeBrowser(); await lab.stopServer(); await lab.startServer(undefined, 1, template);
    context = await lab.launch(); page = await context.newPage(); await open(page, room, actor, "");
    await expect(page.getByRole("button", { name: "Undo my rejected changes", exact: true })).toBeVisible();
    await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveText(`${actor} 😀`);
    await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveAttribute("contenteditable", "false");
    expect((await checkpoint(page, `${room}:${actor}`)).recovery).toEqual(retained.recovery);
    await page.getByRole("button", { name: "Undo my rejected changes", exact: true }).click();
    await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveText("peer 😀");
    await page.getByLabel("Local demo token").fill(token); await page.getByLabel("Connected to local relay").check(); await page.getByRole("button", { name: "Synchronize", exact: true }).click();
    await expect(page.getByRole("status", { name: "Synchronization status" })).toContainText("0 unacknowledged");
    expect((await checkpoint(page, `${room}:${actor}`)).recovery).toBeNull();
    await call("verify", "restoreModern", { actorID: actor, snapshot: (await checkpoint(page, `${room}:${actor}`)).accepted });
    expect(await call("verify", "modernDocument")).toEqual({ ...document, blocks: [{ id: "root", type: "toggle", summary: [], children: [{ id: "same", type: "paragraph", content: [{ type: "text", text: "peer 😀" }] }] }] });
    lab.phases.push({ phase: "modern-recovery-restart", acceptedAndReceiptUnchangedOnRejection: true, retainedProposalReopened: true, explicitOwnUndoRetainsPeer: true });
  } finally { peer.close(); await peer.waitForExit(); try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); } finally { await lab.cleanup(); } }
});

test("modern 8 MB transport failure exports and reopens the complete unacknowledged author archive", async ({ browserName }, info) => {
  const lab = await processLab({ chromium, webkit, firefox }[browserName], info), peer = new NativeBridge(executable);
  const room = "modern-browser-capacity", actor = "browser-author", template = { document: blank(room), epoch };
  const call = (command: string, fields: Record<string, unknown> = {}) => peer.call({ command, session: actor, ...fields });
  try {
    await lab.startServer(undefined, 1, template); const baseline = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json();
    await call("restoreModern", { actorID: actor, snapshot: baseline });
    const boundary = await call("modernCaptureBoundary", { collection: { field: "blocks" } });
    await call("modernCommand", { request: { documentID: room, epoch, command: "insertBlock", target: boundary, arguments: { block: { id: "large", type: "paragraph", content: [], blob: "x".repeat(8_000_000) } } } });
    const pair = await nativePair(peer, room, actor), serverBefore = await lab.savedRoom(room);
    let context = await lab.launch(), page = await context.newPage(); await page.goto("modern-relay.html"); await seed(page, pair); await open(page, room, actor);
    await page.getByRole("button", { name: "Synchronize", exact: true }).click();
    await expect(page.getByRole("alert")).toContainText("8000000");
    expect((await checkpoint(page, `${room}:${actor}`)).accepted).toEqual(pair.accepted); expect((await checkpoint(page, `${room}:${actor}`)).relay?.receipt).toEqual(pair.relay?.receipt);
    expect(await lab.savedRoom(room)).toBe(serverBefore);
    const download = page.waitForEvent("download"); await page.getByRole("button", { name: "Export recovery", exact: true }).click();
    const result = await download, path = await result.path(); expect(path).not.toBeNull();
    const bytes = await readFile(path!), exported = JSON.parse(bytes.toString()); expect(exported.accepted).toEqual(pair.accepted);
    expect(exported.relay.receipt).toEqual(pair.relay?.receipt); expect(exported.token).toBeUndefined();
    const requests = lab.requests; await lab.closeBrowser(); await lab.stopServer(); await lab.startServer(undefined, 1, template);
    context = await lab.launch(); page = await context.newPage(); await open(page, room, actor, ""); expect(lab.requests).toBe(requests);
    const reopened = await checkpoint(page, `${room}:${actor}`); expect(reopened.accepted).toEqual(pair.accepted);
    await peer.call({ command: "restoreModern", session: "verify", actorID: actor, snapshot: reopened.accepted });
    expect((await peer.call({ command: "modernDocument", session: "verify" })).blocks[0].blob).toBe("x".repeat(8_000_000));
    await page.getByLabel("Local demo token").fill(token); await page.getByLabel("Connected to local relay").check(); await page.getByRole("button", { name: "Synchronize", exact: true }).click();
    await expect(page.getByRole("alert")).toContainText("8000000"); expect(await lab.savedRoom(room)).toBe(serverBefore);
    lab.phases.push({ phase: "modern-capacity-restart", maxBytes: 8_000_000, originalCompleteBytes: true, receiptUnchanged: true, retryRemainsRecoverable: true, exportSHA256: createHash("sha256").update(bytes).digest("hex") });
  } finally { peer.close(); await peer.waitForExit(); try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); } finally { await lab.cleanup(); } }
});
