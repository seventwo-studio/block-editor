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
  await page.getByLabel("Connected to local server").uncheck();
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
