# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> ordinary keyboard typing groups until deliberate caret movement and retains Undo selection
- Location: tests/modern-context.swift.ts:34:0

# Error details

```
Error: expect(locator).toHaveText(expected) failed

Locator:  getByRole('textbox', { name: 'Block text', exact: true })
Expected: "Seed"
Received: "Seedab"
Timeout:  5000ms

Call log:
  - Expect "toHaveText" getByRole('textbox', { name: 'Block text', exact: true }) with timeout 5000ms
  - waiting for getByRole('textbox', { name: 'Block text', exact: true })
    14 × locator resolved to <div role="textbox" class="modern-input " aria-multiline="true" contenteditable="true" aria-label="Block text">Seedab</div>
       - unexpected value "Seedab"

```

```yaml
- textbox "Block text"
```

# Test source

```ts
  1   | import { test, expect, type Page } from "@playwright/test";
  2   | import { readFileSync, writeFileSync } from "node:fs";
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
  34  | test("ordinary keyboard typing groups until deliberate caret movement and retains Undo selection", async ({ page }, info) => {
  35  |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "keyboard-history",
  36  |     title: "History", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
  37  |     blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Seed" }] }] };
  38  |   await mount(page, document);
  39  |   await page.evaluate(() => {
  40  |     const session = window.modernAcceptance.session, trace: unknown[] = [];
  41  |     (window as unknown as { typingTrace: unknown[] }).typingTrace = trace;
  42  |     const execute = session.execute.bind(session), select = session.setLocalSelection.bind(session);
  43  |     session.execute = command => {
  44  |       trace.push({ command }); const result = execute(command);
  45  |       trace.push({ afterCommand: session.localSelection() }); return result;
  46  |     };
  47  |     session.setLocalSelection = selection => { trace.push({ beforeSelection: session.localSelection(), selection }); select(selection); };
  48  |   });
  49  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  50  |   await body.click(); await body.press("End"); await page.keyboard.type("abc");
  51  |   await expect(body).toHaveText("Seedabc");
  52  |   const tracePath = info.outputPath("typing-trace.json");
  53  |   writeFileSync(tracePath, JSON.stringify(await page.evaluate(() => ({
  54  |     trace: (window as unknown as { typingTrace: unknown[] }).typingTrace,
  55  |     history: window.modernAcceptance.session.exportHistorySelection(),
  56  |   })), null, 2));
  57  |   await info.attach("typing-command-and-selection-trace", { path: tracePath, contentType: "application/json" });
  58  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
> 59  |   await expect(body).toHaveText("Seed");
      |                     ^ Error: expect(locator).toHaveText(expected) failed
  60  |   await page.getByRole("button", { name: "Redo", exact: true }).click();
  61  |   await expect(body).toHaveText("Seedabc"); await expect(body).toBeFocused();
  62  |   await body.press("ArrowLeft"); await page.keyboard.type("X");
  63  |   await expect(body).toHaveText("SeedabXc");
  64  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  65  |   await expect(body).toHaveText("Seedabc");
  66  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  67  |   await expect(body).toHaveText("Seed");
  68  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  69  | });
  70  | 
  71  | test("editor actions preserve content without submitting an enclosing host form", async ({ page }) => {
  72  |   const document = await mount(page, "unicode");
  73  |   await page.evaluate(() => {
  74  |     const root = window.document.getElementById("root")!;
  75  |     const form = window.document.createElement("form");
  76  |     root.parentElement!.insertBefore(form, root); form.append(root);
  77  |     form.addEventListener("submit", event => { event.preventDefault(); window.modernAcceptance.events.push({ type: "host-submit", target: "host form" }); });
  78  |   });
  79  |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  80  |   await expect(page.getByRole("textbox", { name: "Search blocks", exact: true })).toBeFocused();
  81  |   await page.keyboard.press("Escape");
  82  |   await page.getByRole("button", { name: "Select block", exact: true }).first().click();
  83  |   await page.keyboard.press("Escape");
  84  |   const state = await page.evaluate(() => ({ submits: window.modernAcceptance.events.filter(event => event.type === "host-submit"), document: window.modernAcceptance.session.getSnapshot().document }));
  85  |   expect(state.submits).toEqual([]);
  86  |   expect(state.document).toEqual(document);
  87  | });
  88  | 
  89  | async function trackCellCaptures(page: Page) {
  90  |   await page.evaluate(() => {
  91  |     const { session, events } = window.modernAcceptance, capture = session.captureTableTarget.bind(session);
  92  |     session.captureTableTarget = (...args) => { events.push({ type: "table-capture", target: JSON.stringify(args) }); return capture(...args); };
  93  |   });
  94  | }
  95  | async function captureCount(page: Page) { return page.evaluate(() => window.modernAcceptance.events.filter(event => event.type === "table-capture").length); }
  96  | 
  97  | test("cell actions capture on keyboard opening and retain peer text through author Undo", async ({ page }) => {
  98  |   const original = await mount(page, cellActionsDocument); await trackCellCaptures(page);
  99  |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  100 |   expect(await captureCount(page)).toBe(0);
  101 |   const summary = page.locator('summary[aria-label="Cell actions"]'); await summary.focus(); await summary.press("Enter");
  102 |   await expect(page.getByRole("button", { name: "set Header", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  103 |   await page.evaluate(() => {
  104 |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  105 |     const cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] }), field = peer.field(cell);
  106 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 0), arguments: { text: "Peer: " } }); session.receive(peer.changes());
  107 |   });
  108 |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "set Header", exact: true }).click();
  109 |   await expect(page.getByRole("textbox", { name: "Table header", exact: true })).toHaveText("Peer: Original 世界😀");
  110 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  111 |   const expected = structuredClone(original); ((expected.blocks[0].rows as { cells: { content: { text: string }[] }[] }[])[0].cells[0].content)[0].text = "Peer: Original 世界😀";
  112 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  113 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  114 | });
  115 | 
  116 | test("open cell actions reject incompatible peer structure without refreshing their captured target", async ({ page }) => {
  117 |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  118 |   await page.locator('summary[aria-label="Cell actions"]').click();
  119 |   await expect(page.getByRole("button", { name: "insert Row", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  120 |   await page.evaluate(() => {
  121 |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  122 |     const table = peer.node({ blockID: "T", path: [] }), row = peer.node({ blockID: "T", path: ["rows", "R"] }), cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] });
  123 |     peer.execute({ command: "tableStructure", target: peer.captureTableTarget(table, row, cell), arguments: { action: "insertColumn", newIDs: ["peer-cell"] } }); session.receive(peer.changes());
  124 |   });
  125 |   const before = await page.evaluate(() => window.modernAcceptance.session.save());
  126 |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  127 |   expect(await captureCount(page)).toBe(1);
  128 |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
  129 |   expect(await page.evaluate(() => window.modernAcceptance.errors.length)).toBeGreaterThan(0);
  130 | });
  131 | 
  132 | test("successful cell actions dismiss and reopening captures the updated structure", async ({ page }) => {
  133 |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  134 |   const summary = page.locator('summary[aria-label="Cell actions"]').first(); await summary.click();
  135 |   await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  136 |   await expect(summary.locator('..')).not.toHaveAttribute("open", "");
  137 |   expect(await captureCount(page)).toBe(1);
  138 |   await summary.focus(); await summary.press("Enter");
  139 |   await page.getByRole("button", { name: "insert Column", exact: true }).first().click();
  140 |   const table = await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0]);
  141 |   expect(table.rows).toHaveLength(2);
  142 |   expect((table.rows as { cells: unknown[] }[]).map(row => row.cells.length)).toEqual([2, 2]);
  143 |   expect(await captureCount(page)).toBe(2);
  144 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  145 | });
  146 | 
  147 | test("body presentation retains composition through local menus and updates provider status", async ({ page }) => {
  148 |   const original: ModernDocument = { ...cellActionsDocument, documentID: "body-lifecycle", blocks: [
  149 |     { id: "A", type: "paragraph", content: [{ type: "text", text: "Original " }] },
  150 |     { id: "image", type: "image", src: "https://example.test/asset.png", caption: [], width: 64, height: 64 }
  151 |   ] };
  152 |   await mount(page, original);
  153 |   const input = page.getByRole("textbox", { name: "Block text", exact: true }), slider = page.getByRole("slider", { name: "Image width", exact: true });
  154 |   await input.focus(); await input.dispatchEvent("compositionstart");
  155 |   await input.evaluate(root => { root.textContent = "Original 未確定😀"; });
  156 |   await input.dispatchEvent("input", { inputType: "insertCompositionText", isComposing: true });
  157 |   await expect(slider).toBeDisabled();
  158 |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  159 |   await page.getByRole("textbox", { name: "Search blocks" }).press("Escape");
```