import { expect, test, chromium, firefox, webkit } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { NativeBridge } from "../demo/relay/bridge.ts";
import type { Block } from "../src/schema.ts";
import { executable, headers, token, processLab, readDraft, reopen } from "./helpers/relay-process.ts";

const text = (value: string) => ({ type: "text" as const, text: value, marks: [] });

test("v1 browser processes retain offline author history while relay restart clears presence", async ({ browserName }, testInfo) => {
  const browserType = { chromium, firefox, webkit }[browserName];
  const lab = await processLab(browserType, testInfo);
  const peer = new NativeBridge(executable);
  const room = `restart-${crypto.randomUUID()}`;
  const call = (command: string, args: Record<string, unknown> = {}) => peer.call({ session: "peer", command, ...args });
  const exchange = async (presence?: unknown) => {
    const response = await fetch(`${lab.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({
      actorID: "native-peer", batch: await call("changes"), state: await call("syncState"), presence,
    }) });
    expect(response.status).toBe(200);
    const result = await response.json(); await call("receive", { batch: result.batch }); return result;
  };
  try {
    await lab.startServer();
    const context = await lab.launch(), page = await context.newPage();
    await page.goto("local.html");
    await page.getByLabel("Room", { exact: true }).fill(room);
    await page.getByLabel("Local demo token").fill(token);
    await page.getByRole("button", { name: "Open editor" }).click();
    const editor = page.getByRole("textbox", { name: "Write something…" });
    await expect(page.getByRole("status")).toContainText("0 unacknowledged");
    const client = (await page.evaluate(() => sessionStorage.getItem("editor-client")))!;
    const key = `${room}:${client}`;
    await call("restore", { actorID: "native-peer", snapshot: await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json() });
    await exchange({ actor: "native-peer", revision: 1 });
    await expect(page.getByRole("status")).toContainText("1 other clients");
    const presenceSave = await readDraft(page, key), presenceServer = await lab.savedRoom(room);
    await exchange({ actor: "native-peer", revision: 2, address: { blockID: "p", path: ["content"] } });
    expect(await readDraft(page, key)).toEqual(presenceSave);
    expect(await lab.savedRoom(room)).toBe(presenceServer);
    await expect(page.getByRole("status")).toContainText("0 other clients", { timeout: 10_000 });
    expect(await readDraft(page, key)).toEqual(presenceSave);
    await page.getByLabel("Connected to local server").uncheck();
    await expect(page.getByRole("status")).toContainText("0 other clients");
    await editor.fill("Offline local café 😀");
    await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
    const offline = await readDraft(page, key);
    expect(offline.pending).toBeNull();
    expect(JSON.stringify(offline)).not.toContain(token);
    expect(offline.snapshot).not.toHaveProperty("presence");
    await lab.closeBrowser();
    await lab.stopServer();
    const requestsBeforeReopen = lab.requests;
    const restored = await reopen(await lab.launch(), room, client);
    const restoredEditor = restored.getByRole("textbox", { name: "Write something…" });
    await expect(restoredEditor).toHaveText("Offline local café 😀");
    expect(await readDraft(restored, key)).toEqual(offline);
    expect(lab.requests).toBe(requestsBeforeReopen);
    await restored.getByRole("button", { name: "Undo", exact: true }).click();
    await expect(restoredEditor).toHaveText("Shared local document");
    await restored.getByRole("button", { name: "Redo", exact: true }).click();
    await expect(restoredEditor).toHaveText("Offline local café 😀");
    await lab.startServer();
    const restarted = await exchange();
    expect(restarted.presence).toEqual([]);
    expect(await lab.savedRoom(room)).toBe(presenceServer);
    await call("replaceText", { address: { blockID: "p", path: ["content"] }, start: 21, end: 21, text: " REMOTE 世界" });
    await exchange({ actor: "native-peer", revision: 3 });
    await restored.getByLabel("Local demo token").fill(token);
    await restored.getByLabel("Connected to local server").check();
    await expect(restoredEditor).toContainText("REMOTE 世界");
    await expect(restoredEditor).toContainText("Offline local");
    await expect(restored.getByRole("status")).toContainText("0 unacknowledged");
    await exchange();
    const observer = new NativeBridge(executable);
    try {
      const browserDocument = await observer.call({ command: "restore", session: "observer", actorID: "observer", snapshot: (await readDraft(restored, key)).snapshot });
      expect((await call("document")).blocks).toEqual(browserDocument.blocks);
    } finally { observer.close(); }
    await restored.getByRole("button", { name: "Undo", exact: true }).click();
    await expect(restoredEditor).not.toContainText("Offline local");
    await expect(restoredEditor).toContainText("REMOTE 世界");
    await expect(restored.getByRole("status")).toContainText("0 unacknowledged");
    await restored.getByLabel("Connected to local server").uncheck();
    await expect(restored.getByTestId("local-save")).toHaveText("Saved locally");
    const final = await readDraft(restored, key);
    await lab.closeBrowser();
    const finalPage = await reopen(await lab.launch(), room, client);
    expect(await readDraft(finalPage, key)).toEqual(final);
    await expect(finalPage.getByRole("textbox", { name: "Write something…" })).toContainText("REMOTE 世界");
    lab.phases.push({ phase: "v1-accepted", offlineRequests: 0, undoPreservedRemote: true, presenceChangedSavedContent: false });
  } finally {
    peer.close();
    try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); }
    finally { await lab.cleanup(); }
  }
});

test("v2 pending proposals survive browser and relay process restarts before visible repair and resubmit", async ({ browserName }, testInfo) => {
  const browserType = { chromium, firefox, webkit }[browserName];
  const lab = await processLab(browserType, testInfo);
  const peer = new NativeBridge(executable);
  const room = `recovery-${crypto.randomUUID()}`, client = crypto.randomUUID(), key = `${room}:${client}`;
  const blocks: Block[] = [{ id: "parent", type: "toggle", summary: [text("Parent")], children: [] }];
  const call = (session: string, command: string, args: Record<string, unknown> = {}) => peer.call({ session, command, ...args });
  try {
    await lab.startServer(blocks, 2);
    const snapshot = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json();
    for (const actor of ["alice", "bob"]) {
      await call(actor, "restore", { actorID: actor, snapshot });
      await call(actor, "insertNode", { collection: { owner: { baseline: { blockID: "parent", path: [] } }, field: "children" },
        value: { id: "same", type: "paragraph", content: [text(actor === "alice" ? "café 😀 Alice" : "世界 Bob")] } });
    }
    expect((await fetch(`${lab.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({
      actorID: "alice", batch: await call("alice", "changes"), state: await call("alice", "syncState"),
    }) })).status).toBe(200);
    const acceptedServer = await lab.savedRoom(room), acceptedBob = await call("bob", "save");
    const context = await lab.launch(), page = await context.newPage();
    await page.goto("./");
    await page.evaluate(async ({ key, snapshot }) => {
      const database = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("block-editor-local-lab", 2);
        request.onupgradeneeded = () => request.result.createObjectStore("drafts");
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      await new Promise<void>((resolve, reject) => {
        const transaction = database.transaction("drafts", "readwrite");
        transaction.objectStore("drafts").put({ version: 2, actor: "bob", snapshot, pending: null }, key);
        transaction.oncomplete = () => resolve(); transaction.onabort = () => reject(transaction.error);
      }); database.close();
    }, { key, snapshot: acceptedBob });
    await page.close();
    const pendingPage = await reopen(context, room, client);
    await pendingPage.getByLabel("Local demo token").fill(token);
    await pendingPage.getByLabel("Connected to local server").check();
    await expect(pendingPage.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    await pendingPage.getByLabel("Connected to local server").uncheck();
    await expect(pendingPage.getByTestId("local-save")).toHaveText("Saved locally");
    const pendingDraft = await readDraft(pendingPage, key);
    expect(pendingDraft.snapshot).toEqual(acceptedBob);
    expect(pendingDraft.pending.batch.changes).toHaveLength(2);
    expect(await lab.savedRoom(room)).toBe(acceptedServer);
    await lab.closeBrowser();
    await lab.stopServer();
    const requestsBeforeReopen = lab.requests;
    const reopenedContext = await lab.launch();
    let restored = await reopen(reopenedContext, room, client);
    await expect(restored.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    expect(await readDraft(restored, key)).toEqual(pendingDraft);
    expect(lab.requests).toBe(requestsBeforeReopen);
    await expect(restored.getByRole("button", { name: "Undo", exact: true })).toBeDisabled();
    await expect(restored.getByRole("button", { name: "Insert 20 stress edits" })).toBeDisabled();
    const download = restored.waitForEvent("download");
    await restored.getByRole("button", { name: "Export recovery archive" }).click();
    const archive = JSON.parse(await readFile((await (await download).path())!, "utf8"));
    expect(archive.snapshot).toEqual(pendingDraft.snapshot); expect(archive.pending).toEqual(pendingDraft.pending);
    const importedPage = await reopenedContext.newPage();
    await importedPage.goto("local.html");
    await importedPage.getByLabel("Room", { exact: true }).fill(room);
    await importedPage.getByLabel("Import recovery archive").setInputFiles({
      name: "retained-recovery.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(archive)),
    });
    await expect(importedPage.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    await expect(importedPage.getByLabel("Connected to local server")).not.toBeChecked();
    await expect(importedPage.getByLabel("Local demo token")).toHaveValue("");
    await expect(importedPage.getByTestId("local-save")).toHaveText("Saved locally");
    const importedClient = (await importedPage.evaluate(() => sessionStorage.getItem("editor-client")))!;
    expect(importedClient).not.toBe(client);
    const importedKey = `${room}:${importedClient}`, importedDraft = await readDraft(importedPage, importedKey);
    expect(importedDraft.actor).not.toBe("bob");
    // File imports preserve shared history and start a new author's empty undo
    // stack. Resuming a saved draft retains that draft's own author history.
    const { localHistory: originalHistory, ...originalContent } = pendingDraft.snapshot;
    const { localHistory: importedHistory, ...importedContent } = importedDraft.snapshot;
    expect(importedContent).toEqual(originalContent);
    expect(originalHistory.actorID).toBe("bob");
    expect(importedHistory).toEqual({ actorID: importedDraft.actor, undo: [], redo: [] });
    expect(importedDraft.pending).toEqual(pendingDraft.pending);
    expect(await readDraft(restored, key)).toEqual(pendingDraft);
    expect(lab.requests).toBe(requestsBeforeReopen);
    await lab.closeBrowser();
    const importedContext = await lab.launch();
    const importedReopen = await reopen(importedContext, room, importedClient);
    await expect(importedReopen.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    expect(await readDraft(importedReopen, importedKey)).toEqual(importedDraft);
    expect(lab.requests).toBe(requestsBeforeReopen);
    await importedReopen.close();
    restored = await reopen(importedContext, room, client);
    await restored.getByLabel("Original block").selectOption({ label: "Original toggle: Parent" });
    await restored.getByRole("button", { name: "Place in new toggle" }).click();
    await expect(restored.getByRole("alert").filter({ hasText: "Repair failed" })).toBeVisible();
    expect(await readDraft(restored, key)).toEqual(pendingDraft);
    await restored.getByLabel("Original block").selectOption({ label: "Original paragraph: 世界 Bob" });
    await restored.getByRole("button", { name: "Place in new toggle" }).click();
    await expect(restored.getByRole("region", { name: "Merge recovery" })).toHaveCount(0);
    await expect(restored.getByTestId("local-save")).toHaveText("Saved locally");
    const repaired = await readDraft(restored, key);
    expect(repaired.actor).toBe("bob"); expect(repaired.pending).toBeNull();
    expect(repaired.snapshot.changes).toHaveLength(3);
    await lab.closeBrowser();
    const resubmit = await reopen(await lab.launch(), room, client);
    expect(await readDraft(resubmit, key)).toEqual(repaired);
    expect(lab.requests).toBe(requestsBeforeReopen);
    await lab.startServer(blocks, 2);
    expect(await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json()).toEqual(JSON.parse(acceptedServer));
    await resubmit.getByLabel("Local demo token").fill(token);
    await resubmit.getByLabel("Connected to local server").check();
    await expect(resubmit.getByRole("status")).toContainText("0 unacknowledged");
    await expect(resubmit.getByRole("status")).toContainText("connected");
    await expect(resubmit.getByTestId("local-save")).toHaveText("Saved locally");
    const serverSnapshot = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json();
    const serverDoc = await call("server-observer", "restore", { actorID: "observer", snapshot: serverSnapshot });
    const browserDoc = await call("browser-observer", "restore", { actorID: "observer", snapshot: (await readDraft(resubmit, key)).snapshot });
    expect(browserDoc.blocks).toEqual(serverDoc.blocks);
    expect(JSON.stringify(serverDoc.blocks)).toContain("café 😀 Alice"); expect(JSON.stringify(serverDoc.blocks)).toContain("世界 Bob");
    lab.phases.push({ phase: "v2-accepted", offlineRequests: 0, rejectedAcknowledged: false, proposalRetained: true,
      importedFreshAuthorRetained: true, failedRepairPreserved: true, repairedAuthorsConverged: true });
  } finally {
    peer.close();
    try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); }
    finally { await lab.cleanup(); }
  }
});

test("transport capacity preserves unacknowledged archives across browser and relay process restarts", async ({ browserName }, testInfo) => {
  const lab = await processLab({ chromium, firefox, webkit }[browserName], testInfo);
  const peer = new NativeBridge(executable);
  const room = `capacity-${crypto.randomUUID()}`;
  const call = (command: string, args: Record<string, unknown> = {}) => peer.call({ session: "large-author", command, ...args });
  const rejectedCount = () => lab.phases.filter(phase => phase.phase === "relay-response" && phase.status === 413).length;
  try {
    await lab.startServer([], 2);
    const baseline = await (await fetch(`${lab.url}/rooms/${room}`, { headers })).json();
    const observe = async () => {
      const response = await fetch(`${lab.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({
        actorID: "observer", batch: baseline, state: { received: [] }, presence: null,
      }) });
      expect(response.status).toBe(200); return await response.json();
    };
    const before = await observe(), serverBefore = await lab.savedRoom(room);
    await call("restore", { actorID: "large-author", snapshot: baseline });
    await call("insertNode", { collection: { field: "blocks" }, value: { id: "large", type: "host-extension", blob: "x".repeat(8_000_000) } });
    const snapshot = await call("save"), receipts = await call("syncState");
    const archive = { kind: "block-editor-recovery", version: 1, snapshot, pending: null };
    const context = await lab.launch(), page = await context.newPage();
    await page.goto("local.html");
    await page.getByLabel("Room", { exact: true }).fill(room);
    await page.getByLabel("Import recovery archive").setInputFiles({ name: "large-author.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(archive)) });
    await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
    const client = (await page.evaluate(() => sessionStorage.getItem("editor-client")))!, key = `${room}:${client}`;
    const localBefore = await readDraft(page, key);
    await page.getByLabel("Local demo token").fill(token);
    await page.getByLabel("Connected to local server").check();
    await expect(page.getByRole("region", { name: "Transport capacity" })).toBeVisible();
    await expect(page.getByRole("status")).toContainText("1 unacknowledged");
    await page.getByLabel("Connected to local server").uncheck();
    expect(rejectedCount()).toBeGreaterThan(0);
    expect(await lab.savedRoom(room)).toBe(serverBefore);
    expect(await readDraft(page, key)).toEqual(localBefore);
    const download = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export recovery archive" }).click();
    const retainedArchive = JSON.parse(await readFile((await (await download).path())!, "utf8"));
    expect(retainedArchive.snapshot).toEqual(localBefore.snapshot); expect(retainedArchive.pending).toBeNull();
    expect(retainedArchive.snapshot.changes).toEqual(snapshot.changes);
    await lab.closeBrowser(); await lab.stopServer();
    const offlineRequests = lab.requests;
    const restored = await reopen(await lab.launch(), room, client);
    expect(await readDraft(restored, key)).toEqual(localBefore);
    expect(lab.requests).toBe(offlineRequests);
    await expect(restored.getByRole("status")).toContainText("1 unacknowledged");
    await call("restore", { session: "archive-observer", actorID: "archive-observer", snapshot: retainedArchive.snapshot });
    expect(await call("syncState", { session: "archive-observer" })).toEqual(receipts);
    expect(await call("syncState")).toEqual(receipts);
    const document = await call("document", { session: "archive-observer" });
    expect(document.blocks[0].id).toBe("large"); expect(document.blocks[0].blob).toBe("x".repeat(8_000_000));
    await lab.startServer([], 2);
    expect((await observe()).state).toEqual(before.state);
    expect(await lab.savedRoom(room)).toBe(serverBefore);
    const previousRejected = rejectedCount();
    await restored.getByLabel("Local demo token").fill(token);
    await restored.getByLabel("Connected to local server").check();
    await expect(restored.getByRole("region", { name: "Transport capacity" })).toContainText("8,000,000");
    await restored.getByRole("button", { name: "Retry synchronization" }).click();
    await expect.poll(rejectedCount).toBeGreaterThan(previousRejected + 1);
    await restored.getByLabel("Connected to local server").uncheck();
    expect(await readDraft(restored, key)).toEqual(localBefore);
    const after = await observe();
    expect(after.state).toEqual(before.state); expect(after.presence).toEqual([]);
    expect(await lab.savedRoom(room)).toBe(serverBefore);
    lab.phases.push({ phase: "capacity-retained", limitBytes: 8_000_000, localHistoryBytes: Buffer.byteLength(JSON.stringify(snapshot)),
      rejectedRequests: rejectedCount(), serverAcknowledged: false, archiveRecovered: true, offlineRelayRequests: 0 });
  } finally {
    peer.close();
    try { await lab.closeBrowser(); await lab.stopServer(); await lab.report(); }
    finally { await lab.cleanup(); }
  }
});
