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
