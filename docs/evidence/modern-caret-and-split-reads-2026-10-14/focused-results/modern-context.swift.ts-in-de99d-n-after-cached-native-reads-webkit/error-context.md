# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> input caret follows peer prefixes and author deactivation after cached native reads
- Location: tests/modern-context.swift.ts:51:0

# Error details

```
Error: evaluate: TypeError: peer.undo is not a function. (In 'peer.undo()', 'peer.undo' is undefined)
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
  34  | declare global { interface Window { contextualReadCounts: { marks: number; semantics: number } } }
  35  | 
  36  | test("large-document Unicode composition and adjacent typing retain author history", async ({ page }) => {
  37  |   const document = await mount(page, "migrated-5001");
  38  |   const body = page.getByRole("textbox", { name: "Block text", exact: true }).last();
  39  |   // insertText commits the complete Unicode buffer once. Firefox keyboard.type
  40  |   // starts a separate composition per non-ASCII scalar, a deliberate boundary.
  41  |   await body.scrollIntoViewIfNeeded(); await body.click(); await body.press("End");
  42  |   await page.keyboard.insertText(" 世界😀"); await page.keyboard.type("abc");
  43  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀abc");
  44  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  45  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  46  |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  47  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀abc");
  48  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  49  | });
  50  | 
  51  | test("input caret follows peer prefixes and author deactivation after cached native reads", async ({ page }) => {
  52  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "caret-history",
  53  |     title: "Caret history", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  54  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Seed" }], opaque: { retained: "世界😀" } }
  55  |     ] });
  56  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  57  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  58  |   await expect(body).toHaveText("Seed!");
  59  |   await page.evaluate(() => {
  60  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  61  |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  62  |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 0), arguments: { text: "世界" } });
  63  |     session.receive(peer.changes());
  64  |   });
  65  |   await expect(body).toHaveText("世界Seed!"); await expect(body).toBeFocused();
  66  |   await body.press("ArrowLeft"); await page.keyboard.type("X"); await expect(body).toHaveText("世界SeedX!");
  67  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body).toHaveText("世界Seed!");
  68  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body).toHaveText("世界Seed");
> 69  |   await page.evaluate(() => { const { session, peer } = window.modernAcceptance; peer.undo(); session.receive(peer.changes()); });
      |             ^ Error: evaluate: TypeError: peer.undo is not a function. (In 'peer.undo()', 'peer.undo' is undefined)
  70  |   await expect(body).toHaveText("Seed"); await page.keyboard.type("Y"); await expect(body).toHaveText("SeedY");
  71  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0].opaque)).toEqual({ retained: "世界😀" });
  72  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  73  | });
  74  | 
  75  | test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  76  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
  77  |     title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  78  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
  79  |     ] });
  80  |   await page.evaluate(() => {
  81  |     const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
  82  |     const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
  83  |     session.markState = (...args) => { counts.marks++; return marks(...args); };
  84  |     session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  85  |   });
  86  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  87  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  88  |   await expect(body).toHaveText("Bold plain!");
  89  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  90  |   await body.evaluate(root => { root.focus(); document.getSelection()!.setBaseAndExtent(root, root.childNodes.length, root, 0); });
  91  |   await page.getByText("Format", { exact: true }).click();
  92  |   const bold = page.getByRole("button", { name: "bold", exact: true });
  93  |   await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  94  |   await page.getByText("Format", { exact: true }).click();
  95  |   await expect(bold).not.toBeVisible();
  96  |   await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  97  |   await page.evaluate(() => {
  98  |     window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
  99  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  100 |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  101 |     peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
  102 |     session.receive(peer.changes());
  103 |   });
  104 |   await expect(body.locator("strong")).toHaveText("Bold plain!");
  105 |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  106 |   await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  107 |   await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  108 |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  109 |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  110 |   const backward = () => body.evaluate(root => {
  111 |     const selection = document.getSelection()!, a = document.createRange(), b = document.createRange();
  112 |     a.selectNodeContents(root); a.setEnd(selection.anchorNode!, selection.anchorOffset);
  113 |     b.selectNodeContents(root); b.setEnd(selection.focusNode!, selection.focusOffset);
  114 |     return a.toString().length > b.toString().length;
  115 |   });
  116 |   await expect.poll(backward).toBe(true);
  117 |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  118 |   await expect(body.locator("strong")).toHaveCount(0);
  119 |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  120 |   await expect.poll(backward).toBe(true);
  121 |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  122 |   await page.getByText("Format", { exact: true }).click();
  123 |   await page.getByText("More", { exact: true }).click();
  124 |   const more = page.getByText("More", { exact: true }).locator("..");
  125 |   await more.getByText("Text color: Default", { exact: true }).click();
  126 |   const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  127 |   await ink.getByRole("button", { name: "blue", exact: true }).click();
  128 |   await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
  129 |   expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  130 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  131 | });
  132 | 
  133 | test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  134 |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
  135 |     title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  136 |       { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
  137 |       { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
  138 |     ] });
  139 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  140 |   const outline = page.getByRole("navigation", { name: "Heading outline" });
  141 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  142 |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  143 |   await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  144 |   await page.evaluate(() => {
  145 |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  146 |     const field = peer.field(peer.node({ blockID: "H", path: [] }));
  147 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  148 |   });
  149 |   await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  150 |   await outline.getByRole("button", { name: "Updated", exact: true }).click();
  151 |   await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  152 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  153 |   await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  154 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  155 | });
  156 | 
  157 | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  158 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  159 |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  160 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  161 |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  162 |     ] };
  163 |   await mount(page, document);
  164 |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  165 |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  166 |   await first.click(); await first.press("End"); await page.keyboard.type("abc");
  167 |   await expect(first).toHaveText("Firstabc");
  168 |   await second.click(); await second.press("End"); await second.press("Enter");
  169 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
```