import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.route("**/engine.wasm", route => route.fulfill({ path: "dist/block-editor.wasm", contentType: "application/wasm" }));
  await page.goto("/");
  await page.evaluate(async source => {
    const { mount } = await import(/* @vite-ignore */ source);
    (window as any).selectionHarness = await mount(await (await fetch("engine.wasm")).arrayBuffer());
  }, `/block-editor/@fs${process.cwd()}/tests/swift-selection-harness.ts`);
  await expect(page.locator('#selection-harness [role="textbox"]')).toBeVisible();
});

test("remote insertion preserves a backward selection of an atomic reference", async ({ page }) => {
  await page.evaluate(() => {
    const h = (window as any).selectionHarness;
    h.select(10, 6);
    h.remote(0, 0, "remote ");
    h.remote(0, 0, "more "); // Two receives before React commits.
  });
  await expect(page.locator('#selection-harness [role="textbox"]')).toHaveText("more remote Hello Mira world");
  expect(await page.evaluate(() => ({ range: (window as any).selectionHarness.selection(), text: getSelection()?.toString() })))
    .toEqual({ range: { start: 18, end: 22, backward: true }, text: "Mira" });
});

test("composition commits before queued remote edits without losing marks or references", async ({ page }) => {
  const editor = page.locator('#selection-harness [role="textbox"]');
  await page.evaluate(() => {
    const h = (window as any).selectionHarness;
    h.select(0);
    const root = document.querySelector('#selection-harness [role="textbox"]')!;
    root.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    root.textContent = "漢Hello Mira world";
    h.select(1);
    root.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", isComposing: true, data: "漢" }));
    h.remote(0, 0, "R");
  });
  await expect(editor).toHaveText("漢Hello Mira world");
  expect(await page.evaluate(() => (window as any).selectionHarness.a.syncState().received.length)).toBe(0);
  await editor.dispatchEvent("compositionend", { data: "漢" });
  await expect(editor).toHaveText("R漢Hello Mira world");
  expect(await page.evaluate(() => (window as any).selectionHarness.selection())).toEqual({ start: 2, end: 2, backward: false });
  const nodes = await page.evaluate(() => (window as any).selectionHarness.a.getSnapshot().blocks[0].content);
  expect(nodes).toContainEqual({ type: "mention", entityId: "mira", entityType: "user", label: "Mira" });
  expect(nodes.some((n: any) => n.type === "text" && n.text.includes("Hello ") && n.marks.some((m: any) => m.type === "bold"))).toBe(true);
  expect(nodes.some((n: any) => n.type === "text" && n.text === " world" && n.marks.some((m: any) => m.type === "italic"))).toBe(true);
  await expect(page.locator('#selection-harness [role="alert"]')).toHaveCount(0);
});

test("Chromium IME input commits before applying a concurrent remote insertion", async ({ page, browserName }) => {
  test.skip(browserName !== "chromium", "The Chromium IME protocol is unavailable in WebKit");
  await page.evaluate(() => (window as any).selectionHarness.select(0));
  const ime = await page.context().newCDPSession(page);
  await ime.send("Input.imeSetComposition", { text: "漢", selectionStart: 1, selectionEnd: 1 });
  const editor = page.locator('#selection-harness [role="textbox"]');
  await expect(editor).toHaveText("漢Hello Mira world");
  await page.evaluate(() => (window as any).selectionHarness.remote(0, 0, "R"));
  await expect(editor).toHaveText("漢Hello Mira world");
  await ime.send("Input.insertText", { text: "漢" });
  await expect(editor).toHaveText("R漢Hello Mira world");
  expect(await page.evaluate(() => (window as any).selectionHarness.selection())).toEqual({ start: 2, end: 2, backward: false });
  await expect(page.locator('#selection-harness [role="alert"]')).toHaveCount(0);
});

test("caret inside a reference label follows remote text without changing the reference", async ({ page }) => {
  await page.evaluate(() => {
    const h = (window as any).selectionHarness;
    h.select(8); h.remote(0, 0, "R");
  });
  await expect(page.locator('#selection-harness [role="textbox"]')).toHaveText("RHello Mira world");
  expect(await page.evaluate(() => (window as any).selectionHarness.selection())).toEqual({ start: 9, end: 9, backward: false });
  expect(await page.evaluate(() => (window as any).selectionHarness.a.getSnapshot().blocks[0].content))
    .toContainEqual({ type: "mention", entityId: "mira", entityType: "user", label: "Mira" });
});

test("nested composition holds keep receipt gaps and drain valid batches after a rejection", async ({ page }) => {
  const result = await page.evaluate(() => {
    const { a, b } = (window as any).selectionHarness;
    const first = a.deferRemoteChanges(), second = a.deferRemoteChanges();
    b.replaceText({ blockID: "p", path: ["content"] }, 0, 0, "R", []);
    const batch = b.changes();
    a.receive({ ...batch, version: 99 }); a.receive(batch);
    batch.changes.length = 0; // The caller cannot mutate an already queued message.
    first();
    const before = a.syncState().received.length;
    let rejected = false;
    try { second(); } catch { rejected = true; }
    second(); // Release is idempotent even after an invalid batch.
    const after = a.syncState().received.length;
    return { before, after, rejected, text: a.getSnapshot().blocks[0].content.map((n: any) => n.text ?? n.label).join("") };
  });
  expect(result).toEqual({ before: 0, after: 1, rejected: true, text: "RHello Mira world" });
});

test("a rejected remote batch cannot restore an obsolete selection later", async ({ page }) => {
  await page.evaluate(() => {
    const h = (window as any).selectionHarness;
    h.select(6, 10);
    try { h.a.receive({ ...h.b.changes(), version: 99 }); } catch { }
    h.select(10, 16);
    h.remote(0, 0, "R");
  });
  await expect(page.locator('#selection-harness [role="textbox"]')).toHaveText("RHello Mira world");
  expect(await page.evaluate(() => ({ range: (window as any).selectionHarness.selection(), text: getSelection()?.toString() })))
    .toEqual({ range: { start: 11, end: 17, backward: false }, text: " world" });
});

test("remote updates do not steal focus from another input", async ({ page }) => {
  await page.evaluate(() => {
    const h = (window as any).selectionHarness;
    h.select(6, 10);
    const input = document.createElement("input"); input.id = "other-input";
    document.body.append(input); input.focus();
    h.remote(0, 0, "R");
  });
  await expect(page.locator('#selection-harness [role="textbox"]')).toHaveText("RHello Mira world");
  await expect(page.locator("#other-input")).toBeFocused();
});
