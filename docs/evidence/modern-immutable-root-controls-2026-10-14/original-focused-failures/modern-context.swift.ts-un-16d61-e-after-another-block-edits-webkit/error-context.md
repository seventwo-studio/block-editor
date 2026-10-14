# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> unchanged sibling commands use current shared state after another block edits
- Location: tests/modern-context.swift.ts:34:0

# Error details

```
Error: expect(locator).toHaveText(expected) failed

Locator:  getByRole('textbox', { name: 'Block text', exact: true }).first()
Expected: "Firstabc"
Received: "abcFirst"
Timeout:  5000ms

Call log:
  - Expect "toHaveText" getByRole('textbox', { name: 'Block text', exact: true }).first() with timeout 5000ms
  - waiting for getByRole('textbox', { name: 'Block text', exact: true }).first()
    14 × locator resolved to <div role="textbox" class="modern-input " aria-multiline="true" contenteditable="true" aria-label="Block text">abcFirst</div>
       - unexpected value "abcFirst"

```

```yaml
- textbox "Block text"
```

# Test source

```ts
  1   | import { test, expect, type Page } from "@playwright/test";
  2   | import { readFileSync } from "node:fs";
  3   | import { resolve } from "node:path";
  4   | import type { ModernDocument } from "../src/swift-modern.js";
  5   | import type {} from "./helpers/modern-surface.js";
  6   | 
  7   | async function mount(page: Page, fixture: string | ModernDocument) {
  8   |   const document = typeof fixture === "string" ? JSON.parse(readFileSync(resolve("docs/acceptance/modern-editor/documents", `${fixture}.json`), "utf8")) as ModernDocument : fixture;
  9   |   await page.route("**/modern-engine.wasm", route => route.fulfill({ path: resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm"), contentType: "application/wasm" }));
  10  |   await page.goto(`/block-editor/@fs${process.cwd()}/tests/helpers/modern-surface.html`);
  11  |   await page.evaluate(async ({ root, documentJSON }) => {
  12  |     const { mountModernSurface } = await import(/* @vite-ignore */ `${root}/tests/helpers/modern-surface.tsx`);
  13  |     window.modernAcceptance = await mountModernSurface(JSON.parse(documentJSON));
  14  |   }, { root: `/block-editor/@fs${process.cwd()}`, documentJSON: JSON.stringify(document) });
  15  |   await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toBeVisible();
  16  |   return document;
  17  | }
  18  | 
  19  | test.afterEach(async ({ page }, info) => {
  20  |   if (info.status !== info.expectedStatus) {
  21  |     const state = await page.evaluate(() => window.modernAcceptance ? { document: window.modernAcceptance.session.getSnapshot().document, events: window.modernAcceptance.events, errors: window.modernAcceptance.errors } : undefined);
  22  |     await info.attach("original-failed-state", { body: JSON.stringify(state, null, 2), contentType: "application/json" });
  23  |     await info.attach("original-failed-dom", { body: await page.content(), contentType: "text/html" });
  24  |     await page.screenshot({ path: info.outputPath("original-failed-surface.png"), fullPage: true });
  25  |   }
  26  |   await page.evaluate(() => window.modernAcceptance?.dispose());
  27  | });
  28  | 
  29  | const cellActionsDocument: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "cell-actions",
  30  |   title: "Checked cell actions", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  31  |     { id: "T", type: "table", rows: [{ id: "R", cells: [{ id: "C", header: false, content: [{ type: "text", text: "Original 世界😀" }] }] }] }
  32  |   ] };
  33  | 
  34  | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  35  |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  36  |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  37  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  38  |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  39  |     ] };
  40  |   await mount(page, document);
  41  |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  42  |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  43  |   await first.focus(); await first.press("End"); await page.keyboard.type("abc");
> 44  |   await expect(first).toHaveText("Firstabc");
      |                      ^ Error: expect(locator).toHaveText(expected) failed
  45  |   await second.focus(); await second.press("End"); await second.press("Enter");
  46  |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
  47  |   await expect(first).toHaveText("Firstabc"); await expect(second).toHaveText("Second");
  48  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  49  |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(2);
  50  |   await expect(first).toHaveText("Firstabc");
  51  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  52  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  53  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  54  | });
  55  | 
  56  | test("ordinary keyboard typing groups until deliberate caret movement and retains Undo selection", async ({ page }) => {
  57  |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "keyboard-history",
  58  |     title: "History", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
  59  |     blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Seed" }] }] };
  60  |   await mount(page, document);
  61  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  62  |   await body.click(); await body.press("End"); await page.keyboard.insertText("😀é"); await page.keyboard.type("abc");
  63  |   await expect(body).toHaveText("Seed😀éabc");
  64  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  65  |   await expect(body).toHaveText("Seed");
  66  |   await expect(body).toBeFocused(); await body.press("ControlOrMeta+Shift+z");
  67  |   await expect(body).toHaveText("Seed😀éabc"); await expect(body).toBeFocused();
  68  |   await body.press("ArrowLeft"); await page.keyboard.type("XY");
  69  |   await expect(body).toHaveText("Seed😀éabXYc");
  70  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  71  |   await expect(body).toHaveText("Seed😀éabc");
  72  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  73  |   await expect(body).toHaveText("Seed");
  74  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  75  | });
  76  | 
  77  | test("editor actions preserve content without submitting an enclosing host form", async ({ page }) => {
  78  |   const document = await mount(page, "unicode");
  79  |   await page.evaluate(() => {
  80  |     const root = window.document.getElementById("root")!;
  81  |     const form = window.document.createElement("form");
  82  |     root.parentElement!.insertBefore(form, root); form.append(root);
  83  |     form.addEventListener("submit", event => { event.preventDefault(); window.modernAcceptance.events.push({ type: "host-submit", target: "host form" }); });
  84  |   });
  85  |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  86  |   await expect(page.getByRole("textbox", { name: "Search blocks", exact: true })).toBeFocused();
  87  |   await page.keyboard.press("Escape");
  88  |   await page.getByRole("button", { name: "Select block", exact: true }).first().click();
  89  |   await page.keyboard.press("Escape");
  90  |   const state = await page.evaluate(() => ({ submits: window.modernAcceptance.events.filter(event => event.type === "host-submit"), document: window.modernAcceptance.session.getSnapshot().document }));
  91  |   expect(state.submits).toEqual([]);
  92  |   expect(state.document).toEqual(document);
  93  | });
  94  | 
  95  | async function trackCellCaptures(page: Page) {
  96  |   await page.evaluate(() => {
  97  |     const { session, events } = window.modernAcceptance, capture = session.captureTableTarget.bind(session);
  98  |     session.captureTableTarget = (...args) => { events.push({ type: "table-capture", target: JSON.stringify(args) }); return capture(...args); };
  99  |   });
  100 | }
  101 | async function captureCount(page: Page) { return page.evaluate(() => window.modernAcceptance.events.filter(event => event.type === "table-capture").length); }
  102 | 
  103 | test("cell actions capture on keyboard opening and retain peer text through author Undo", async ({ page }) => {
  104 |   const original = await mount(page, cellActionsDocument); await trackCellCaptures(page);
  105 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  106 |   expect(await captureCount(page)).toBe(0);
  107 |   const summary = page.locator('summary[aria-label="Cell actions"]'); await summary.focus(); await summary.press("Enter");
  108 |   await expect(page.getByRole("button", { name: "set Header", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  109 |   await page.evaluate(() => {
  110 |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  111 |     const cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] }), field = peer.field(cell);
  112 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 0), arguments: { text: "Peer: " } }); session.receive(peer.changes());
  113 |   });
  114 |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "set Header", exact: true }).click();
  115 |   await expect(page.getByRole("textbox", { name: "Table header", exact: true })).toHaveText("Peer: Original 世界😀");
  116 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  117 |   const expected = structuredClone(original); ((expected.blocks[0].rows as { cells: { content: { text: string }[] }[] }[])[0].cells[0].content)[0].text = "Peer: Original 世界😀";
  118 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  119 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  120 | });
  121 | 
  122 | test("open cell actions reject incompatible peer structure without refreshing their captured target", async ({ page }) => {
  123 |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  124 |   await page.locator('summary[aria-label="Cell actions"]').click();
  125 |   await expect(page.getByRole("button", { name: "insert Row", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  126 |   await page.evaluate(() => {
  127 |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  128 |     const table = peer.node({ blockID: "T", path: [] }), row = peer.node({ blockID: "T", path: ["rows", "R"] }), cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] });
  129 |     peer.execute({ command: "tableStructure", target: peer.captureTableTarget(table, row, cell), arguments: { action: "insertColumn", newIDs: ["peer-cell"] } }); session.receive(peer.changes());
  130 |   });
  131 |   const before = await page.evaluate(() => window.modernAcceptance.session.save());
  132 |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  133 |   expect(await captureCount(page)).toBe(1);
  134 |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
  135 |   expect(await page.evaluate(() => window.modernAcceptance.errors.length)).toBeGreaterThan(0);
  136 | });
  137 | 
  138 | test("successful cell actions dismiss and reopening captures the updated structure", async ({ page }) => {
  139 |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  140 |   const summary = page.locator('summary[aria-label="Cell actions"]').first(); await summary.click();
  141 |   await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  142 |   await expect(summary.locator('..')).not.toHaveAttribute("open", "");
  143 |   expect(await captureCount(page)).toBe(1);
  144 |   await summary.focus(); await summary.press("Enter");
```