import { test, expect } from "@playwright/test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

test("browser WASM and native Swift rejoin the same local server document", async ({ page, context }) => {
  const room = `browser-${crypto.randomUUID()}`;
  const second = await context.newPage();
  for (const client of [page, second]) {
    await client.goto("local.html");
    await client.getByLabel("Room", { exact: true }).fill(room);
    await client.getByLabel("Local demo token").fill("relay-test");
    await client.getByRole("button", { name: "Open editor" }).click();
    await expect(client.getByRole("textbox", { name: "Write something…" })).toBeVisible();
    await expect(client.getByRole("status")).toContainText("connected");
  }
  await expect(page.getByRole("status")).toContainText("1 other clients");
  await page.route("**/relay/rooms/**", route => route.fulfill({ status: 503, body: "Temporarily unavailable" }));
  await expect(page.getByRole("alert")).toContainText("Temporarily unavailable");
  await page.unroute("**/relay/rooms/**");
  await expect(page.getByRole("status")).toContainText("connected");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.getByLabel("Connected to local server").uncheck();
  await expect(page.getByRole("status")).toContainText("0 other clients");
  await second.getByLabel("Connected to local server").uncheck();
  await page.getByRole("textbox", { name: "Write something…" }).fill("Alice offline 😀");
  await second.getByRole("textbox", { name: "Write something…" }).fill("Bob offline 世界");
  // Real Foundation URLSession client makes an independent offline edit and rejoins.
  await promisify(execFile)(".build/debug/relay-client", [], { env: { ...process.env, DEMO_TOKEN: "relay-test", DEMO_ENDPOINT: `http://127.0.0.1:4319/rooms/${room}` } });
  await page.getByLabel("Connected to local server").check();
  await second.getByLabel("Connected to local server").check();
  const editor = page.getByRole("textbox", { name: "Write something…" });
  const other = second.getByRole("textbox", { name: "Write something…" });
  await expect(editor).toContainText("native offline edit");
  await expect(editor).toContainText("Alice offline");
  await expect(editor).toContainText("Bob offline");
  await expect.poll(async () => await editor.textContent() === await other.textContent()).toBe(true);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(editor).not.toContainText("Alice offline");
  await expect(editor).toContainText("Bob offline");
  await expect(editor).toContainText("native offline edit");
  await expect.poll(async () => await editor.textContent() === await other.textContent()).toBe(true);
  await expect(page.getByRole("status")).toContainText("0 unacknowledged");
});

test("offline browser draft survives reload with local undo and rejoins remote edits", async ({ page, context }) => {
  const room = `restart-${crypto.randomUUID()}`;
  const other = await context.newPage();
  for (const client of [page, other]) {
    await client.goto("local.html");
    await client.getByLabel("Room", { exact: true }).fill(room);
    await client.getByLabel("Local demo token").fill("relay-test");
    await client.getByRole("button", { name: "Open editor" }).click();
    await expect(client.getByRole("status")).toContainText("connected");
  }
  await page.getByLabel("Connected to local server").uncheck();
  await page.getByRole("textbox", { name: "Write something…" }).fill("Persisted offline 😀");
  await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
  await other.getByRole("textbox", { name: "Write something…" }).fill("Remote meanwhile 世界");
  await expect(other.getByRole("status")).toContainText("0 unacknowledged");
  let relayRequests = 0;
  await page.route("**/relay/rooms/**", route => { relayRequests++; return route.abort(); });
  await page.reload();
  await expect(page.getByLabel("Local demo token")).toHaveValue("");
  await page.getByRole("button", { name: "Open editor" }).click();
  const editor = page.getByRole("textbox", { name: "Write something…" });
  await expect(editor).toHaveText("Persisted offline 😀");
  await expect(page.getByLabel("Connected to local server")).not.toBeChecked();
  const clientID = await page.evaluate(() => sessionStorage.getItem("editor-client"));
  const duplicate = await context.newPage();
  await duplicate.addInitScript(({ clientID, room }) => {
    sessionStorage.setItem("editor-client", clientID!); sessionStorage.setItem("editor-room", room);
  }, { clientID, room });
  await duplicate.goto("local.html");
  await duplicate.getByRole("button", { name: "Open editor" }).click();
  await expect(duplicate.getByRole("alert")).toContainText("already open in another tab");
  await duplicate.close();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(editor).toHaveText("Shared local document");
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect(editor).toHaveText("Persisted offline 😀");
  expect(relayRequests).toBe(0);
  await page.unroute("**/relay/rooms/**");
  await page.getByLabel("Local demo token").fill("relay-test");
  await page.getByLabel("Connected to local server").check();
  await expect(editor).toContainText("Remote meanwhile");
  await expect(editor).toContainText("Persisted offline");
  await expect.poll(async () => await editor.textContent() === await other.getByRole("textbox", { name: "Write something…" }).textContent()).toBe(true);
  await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
  await page.close();
  const reopened = await context.newPage();
  await reopened.goto("local.html");
  await reopened.getByLabel("Room", { exact: true }).fill(room);
  await reopened.getByLabel("Saved local draft").selectOption(clientID!);
  await reopened.getByRole("button", { name: "Open editor" }).click();
  const restored = reopened.getByRole("textbox", { name: "Write something…" });
  await expect(restored).toContainText("Persisted offline");
  await expect(restored).toContainText("Remote meanwhile");
  await reopened.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(restored).not.toContainText("Persisted offline");
  await expect(restored).toContainText("Remote meanwhile");
  await expect(reopened.getByTestId("local-save")).toHaveText("Saved locally");
  await reopened.evaluate(() => {
    IDBObjectStore.prototype.put = () => { throw new DOMException("Storage is full", "QuotaExceededError"); };
  });
  await restored.fill("Unsaved because storage is full");
  await expect(reopened.getByTestId("local-save")).toContainText("Local save failed");
  await expect(restored).toHaveText("Unsaved because storage is full");
});

// Exercise the actual browser host against a v2 relay, not an injected engine error.
test("browser retains rejected histories across offline close/reopen and repairs after server restart", async ({ page, context }) => {
  const { startRelay } = await import("../demo/relay/server.ts");
  const { NativeBridge } = await import("../demo/relay/bridge.ts");
  const { mkdtemp, readFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const directory = await mkdtemp(join(tmpdir(), "browser-recovery-"));
  const executable = ".build/debug/editor-bridge";
  const room = `recovery-${crypto.randomUUID()}`, client = crypto.randomUUID();
  const text = (text: string) => ({ type: "text" as const, text, marks: [] });
  const blocks = [{ id: "parent", type: "toggle" as const, summary: [text("Parent")], children: [] }];
  const options = { executable, directory, port: 0, token: "relay-test", blocks, collaborationVersion: 2 as const };
  let relay: Awaited<ReturnType<typeof startRelay>> | undefined = await startRelay(options);
  const bridge = new NativeBridge(executable);
  const headers = { "x-local-token": "relay-test", "content-type": "application/json" };
  const call = (session: string, command: string, args: Record<string, unknown> = {}) => bridge.call({ session, command, ...args });
  const readDraft = async (clientPage = page) => clientPage.evaluate(async key => {
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("block-editor-local-lab", 2);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    try { return await new Promise<any>((resolve, reject) => {
      const request = database.transaction("drafts").objectStore("drafts").get(key);
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    }); } finally { database.close(); }
  }, `${room}:${client}`);
  try {
    const baseline = await (await fetch(`${relay.url}/rooms/${room}`, { headers })).json();
    for (const actor of ["alice", "bob"]) {
      await call(actor, "restore", { actorID: actor, snapshot: baseline });
      await call(actor, "insertNode", { value: { id: "same", type: "paragraph", content: [text(actor === "alice" ? "café 😀 Alice" : "世界 Bob")] },
        collection: { owner: { baseline: { blockID: "parent", path: [] } }, field: "children" } });
    }
    expect((await fetch(`${relay.url}/rooms/${room}`, { method: "POST", headers, body: JSON.stringify({ actorID: "alice", batch: await call("alice", "changes"), state: await call("alice", "syncState") }) })).status).toBe(200);
    const acceptedServer = await readFile(join(directory, `${room}.json`), "utf8");
    const acceptedBob = await call("bob", "save");
    await page.goto("./");
    // Seed an actual legacy IndexedDB draft. Opening the host upgrades it without
    // resetting the exclusive writer or its local history.
    await page.evaluate(async ({ room, client, snapshot }) => {
      sessionStorage.setItem("editor-room", room); sessionStorage.setItem("editor-client", client);
      const database = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("block-editor-local-lab", 1);
        request.onupgradeneeded = () => request.result.createObjectStore("drafts");
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      await new Promise<void>((resolve, reject) => {
        const transaction = database.transaction("drafts", "readwrite");
        transaction.objectStore("drafts").put({ actor: "bob", snapshot }, `${room}:${client}`);
        transaction.oncomplete = () => resolve(); transaction.onabort = () => reject(transaction.error);
      }); database.close();
    }, { room, client, snapshot: acceptedBob });
    let relayRequests = 0;
    const forward = async (route: import("@playwright/test").Route) => {
      relayRequests++;
      if (!relay) { await route.abort(); return; }
      const response = await route.fetch({ url: `${relay.url}${new URL(route.request().url()).pathname.replace(/^\/relay/, "")}` });
      await route.fulfill({ response });
    };
    await context.route("**/relay/rooms/**", forward);
    await page.goto("local.html");
    await page.getByRole("button", { name: "Open editor" }).click();
    await expect(page.getByRole("button", { name: "Undo", exact: true })).toBeEnabled();
    expect(await readDraft()).toEqual({ version: 2, actor: "bob", snapshot: acceptedBob, pending: null });
    await page.evaluate(() => {
      (window as any).originalDraftPut = IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put = () => { throw new DOMException("Storage is full", "QuotaExceededError"); };
    });
    await page.getByLabel("Local demo token").fill("relay-test");
    await page.getByLabel("Connected to local server").check();
    await expect(page.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    await expect(page.getByTestId("local-save")).toContainText("Local save failed");
    expect((await readDraft()).pending).toBeNull();
    const unsavedDownloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export recovery archive" }).click();
    const unsavedArchive = JSON.parse(await readFile((await (await unsavedDownloadPromise).path())!, "utf8"));
    expect(unsavedArchive.snapshot).toEqual(acceptedBob); expect(unsavedArchive.pending.batch.changes).toHaveLength(2);
    await page.evaluate(() => { IDBObjectStore.prototype.put = (window as any).originalDraftPut; });
    await page.getByRole("button", { name: "Retry local save" }).click();
    await expect(page.getByTestId("local-save")).toHaveText("Saved locally");
    await page.getByLabel("Connected to local server").uncheck();
    const pendingDraft = await readDraft();
    expect(pendingDraft.snapshot).toEqual(acceptedBob);
    expect(pendingDraft.pending.batch.changes).toHaveLength(2);
    expect(await readFile(join(directory, `${room}.json`), "utf8")).toBe(acceptedServer);
    await expect(page.getByRole("button", { name: "Undo", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Add paragraph", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Insert 20 stress edits" })).toBeDisabled();
    await page.locator("details > summary").click();
    const acceptedText = page.getByRole("textbox", { name: "Write something…" }).filter({ hasText: "世界 Bob" });
    await expect(acceptedText).toHaveAttribute("contenteditable", "false");
    await acceptedText.evaluate(element => {
      const range = document.createRange(); range.selectNodeContents(element);
      getSelection()!.removeAllRanges(); getSelection()!.addRange(range);
    });
    expect(await page.evaluate(() => getSelection()?.toString())).toBe("世界 Bob");
    await acceptedText.press("X");
    await expect(acceptedText).toHaveText("世界 Bob");
    await page.getByLabel("Original block").selectOption({ label: "Original toggle: Parent" });
    await page.getByRole("button", { name: "Place in new toggle" }).click();
    await expect(page.getByRole("alert").filter({ hasText: "Repair failed" })).toBeVisible();
    expect(await readDraft()).toEqual(pendingDraft);
    const downloadPromise = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export recovery archive" }).click();
    const download = await downloadPromise;
    const archive = JSON.parse(await readFile((await download.path())!, "utf8"));
    expect(archive.snapshot).toEqual(acceptedBob); expect(archive.pending).toEqual(pendingDraft.pending);
    // Old bundles cannot reopen the upgraded DB and overwrite its retained proposal.
    expect(await page.evaluate(() => new Promise<string>(resolve => {
      const request = indexedDB.open("block-editor-local-lab", 1);
      request.onerror = () => resolve(request.error!.name); request.onsuccess = () => { request.result.close(); resolve("opened"); };
    }))).toBe("VersionError");
    await page.close();
    await relay.close(); relay = undefined;
    const offlineRequests = relayRequests;
    const reopened = await context.newPage();
    await reopened.goto("local.html");
    await reopened.getByLabel("Room", { exact: true }).fill(room);
    await reopened.getByLabel("Saved local draft").selectOption(client);
    await reopened.getByRole("button", { name: "Open editor" }).click();
    await expect(reopened.getByRole("region", { name: "Merge recovery" })).toBeVisible();
    await expect(reopened.getByLabel("Local demo token")).toHaveValue("");
    expect(relayRequests).toBe(offlineRequests);
    expect(await readDraft(reopened)).toEqual(pendingDraft);
    await reopened.getByLabel("Original block").selectOption({ label: "Original paragraph: 世界 Bob" });
    await reopened.getByRole("button", { name: "Place in new toggle" }).click();
    await expect(reopened.getByRole("region", { name: "Merge recovery" })).toHaveCount(0);
    await expect(reopened.getByTestId("local-save")).toHaveText("Saved locally");
    const repairedDraft = await readDraft(reopened);
    expect(repairedDraft.actor).toBe("bob"); expect(repairedDraft.pending).toBeNull();
    expect(repairedDraft.snapshot.changes).toHaveLength(3);
    await reopened.close();
    const repairedReopen = await context.newPage();
    await repairedReopen.goto("local.html");
    await repairedReopen.getByLabel("Room", { exact: true }).fill(room);
    await repairedReopen.getByLabel("Saved local draft").selectOption(client);
    await repairedReopen.getByRole("button", { name: "Open editor" }).click();
    await expect(repairedReopen.getByRole("button", { name: "Undo", exact: true })).toBeEnabled();
    expect(await readDraft(repairedReopen)).toEqual(repairedDraft);
    relay = await startRelay(options);
    await repairedReopen.getByLabel("Local demo token").fill("relay-test");
    await repairedReopen.getByLabel("Connected to local server").check();
    await expect(repairedReopen.getByRole("status")).toContainText("0 unacknowledged");
    await expect(repairedReopen.getByRole("status")).toContainText("connected");
    const serverSnapshot = await (await fetch(`${relay.url}/rooms/${room}`, { headers })).json();
    await call("peer", "restore", { actorID: "fresh-peer", snapshot: serverSnapshot });
    const peer = await call("peer", "document");
    expect(JSON.stringify(peer.blocks)).toContain("世界 Bob"); expect(JSON.stringify(peer.blocks)).toContain("café 😀 Alice");
    await call("saved-peer", "restore", { actorID: "another-peer", snapshot: (await readDraft(repairedReopen)).snapshot });
    expect((await call("saved-peer", "document")).blocks).toEqual(peer.blocks);
    await repairedReopen.getByLabel("Connected to local server").uncheck();
    await repairedReopen.close();
  } finally { bridge.close(); if (relay) await relay.close(); await rm(directory, { recursive: true, force: true }); }
});

for (const invalid of ["future storage", "future protocol", "malformed history", "wrong document"] as const) {
  test(`browser preserves a draft with ${invalid} recovery data`, async ({ page, request }) => {
    const room = `invalid-${crypto.randomUUID()}`, client = crypto.randomUUID();
    const response = await request.get(`http://127.0.0.1:4319/rooms/${room}`, { headers: { "x-local-token": "relay-test" } });
    const snapshot = { ...await response.json(), version: 2 };
    const pending = { reason: "identityConflict", batch: { ...snapshot, changes: [] as unknown[] } };
    const draft = { version: 2, actor: "preserved-writer", snapshot, pending };
    if (invalid === "future storage") draft.version = 99;
    if (invalid === "future protocol") pending.batch.version = 99;
    if (invalid === "malformed history") pending.batch.changes = [{ id: { counter: 1, actor: "remote" }, body: { edit: { _0: [{ unknownMutation: {} }] } } }];
    if (invalid === "wrong document") pending.batch.documentID = "different-document";
    await page.goto("./");
    await page.evaluate(async ({ room, client, draft }) => {
      sessionStorage.setItem("editor-room", room); sessionStorage.setItem("editor-client", client);
      const database = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open("block-editor-local-lab", 2);
        request.onupgradeneeded = () => request.result.createObjectStore("drafts");
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      await new Promise<void>((resolve, reject) => {
        const transaction = database.transaction("drafts", "readwrite");
        transaction.objectStore("drafts").put(draft, `${room}:${client}`);
        transaction.oncomplete = () => resolve(); transaction.onabort = () => reject(transaction.error);
      }); database.close();
    }, { room, client, draft });
    let relayRequests = 0;
    await page.route("**/relay/rooms/**", route => { relayRequests++; return route.abort(); });
    await page.goto("local.html");
    await page.getByRole("button", { name: "Open editor" }).click();
    await expect(page.getByRole("alert")).toBeVisible();
    await expect(page.getByRole("button", { name: "Open editor" })).toBeVisible();
    expect(relayRequests).toBe(0);
    const retained = await page.evaluate(async key => {
      const database = await new Promise<IDBDatabase>(resolve => { const request = indexedDB.open("block-editor-local-lab", 2); request.onsuccess = () => resolve(request.result); });
      const value = await new Promise<any>(resolve => { const request = database.transaction("drafts").objectStore("drafts").get(key); request.onsuccess = () => resolve(request.result); });
      database.close(); return value;
    }, `${room}:${client}`);
    expect(retained).toEqual(draft);
  });
}
