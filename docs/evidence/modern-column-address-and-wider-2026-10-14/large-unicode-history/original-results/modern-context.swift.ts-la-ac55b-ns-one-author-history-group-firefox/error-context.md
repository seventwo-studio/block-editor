# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> large-document Unicode typing remains one author history group
- Location: tests/modern-context.swift.ts:36:0

# Error details

```
Error: expect(received).toEqual(expected) // deep equality

- Expected  - 1
+ Received  + 1

@@ -50006,11 +50006,11 @@
        "type": "paragraph",
      },
      Object {
        "content": Array [
          Object {
-           "text": "Preserved legacy paragraph 5000",
+           "text": "Preserved legacy paragraph 5000 世界",
            "type": "text",
          },
        ],
        "id": "legacy-5000",
        "type": "paragraph",
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
  36  | test("large-document Unicode typing remains one author history group", async ({ page }) => {
  37  |   const document = await mount(page, "migrated-5001");
  38  |   const body = page.getByRole("textbox", { name: "Block text", exact: true }).last();
  39  |   await body.scrollIntoViewIfNeeded(); await body.click(); await body.press("End"); await page.keyboard.type(" 世界😀");
  40  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀");
  41  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
> 42  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
      |                                                                                            ^ Error: expect(received).toEqual(expected) // deep equality
  43  |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  44  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀");
  45  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  46  | });
  47  | 
  48  | test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  49  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
  50  |     title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  51  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
  52  |     ] });
  53  |   await page.evaluate(() => {
  54  |     const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
  55  |     const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
  56  |     session.markState = (...args) => { counts.marks++; return marks(...args); };
  57  |     session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  58  |   });
  59  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  60  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  61  |   await expect(body).toHaveText("Bold plain!");
  62  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  63  |   await body.evaluate(root => { root.focus(); document.getSelection()!.setBaseAndExtent(root, root.childNodes.length, root, 0); });
  64  |   await page.getByText("Format", { exact: true }).click();
  65  |   const bold = page.getByRole("button", { name: "bold", exact: true });
  66  |   await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  67  |   await page.getByText("Format", { exact: true }).click();
  68  |   await expect(bold).not.toBeVisible();
  69  |   await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  70  |   await page.evaluate(() => {
  71  |     window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
  72  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  73  |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  74  |     peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
  75  |     session.receive(peer.changes());
  76  |   });
  77  |   await expect(body.locator("strong")).toHaveText("Bold plain!");
  78  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  79  |   await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  80  |   await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  81  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  82  |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  83  |   const backward = () => body.evaluate(root => {
  84  |     const selection = document.getSelection()!, a = document.createRange(), b = document.createRange();
  85  |     a.selectNodeContents(root); a.setEnd(selection.anchorNode!, selection.anchorOffset);
  86  |     b.selectNodeContents(root); b.setEnd(selection.focusNode!, selection.focusOffset);
  87  |     return a.toString().length > b.toString().length;
  88  |   });
  89  |   await expect.poll(backward).toBe(true);
  90  |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  91  |   await expect(body.locator("strong")).toHaveCount(0);
  92  |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  93  |   await expect.poll(backward).toBe(true);
  94  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  95  |   await page.getByText("Format", { exact: true }).click();
  96  |   await page.getByText("More", { exact: true }).click();
  97  |   const more = page.getByText("More", { exact: true }).locator("..");
  98  |   await more.getByText("Text color: Default", { exact: true }).click();
  99  |   const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  100 |   await ink.getByRole("button", { name: "blue", exact: true }).click();
  101 |   await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
  102 |   expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  103 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  104 | });
  105 | 
  106 | test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  107 |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
  108 |     title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  109 |       { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
  110 |       { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
  111 |     ] });
  112 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  113 |   const outline = page.getByRole("navigation", { name: "Heading outline" });
  114 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  115 |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  116 |   await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  117 |   await page.evaluate(() => {
  118 |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  119 |     const field = peer.field(peer.node({ blockID: "H", path: [] }));
  120 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  121 |   });
  122 |   await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  123 |   await outline.getByRole("button", { name: "Updated", exact: true }).click();
  124 |   await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  125 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  126 |   await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  127 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  128 | });
  129 | 
  130 | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  131 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  132 |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  133 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  134 |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  135 |     ] };
  136 |   await mount(page, document);
  137 |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  138 |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  139 |   await first.click(); await first.press("End"); await page.keyboard.type("abc");
  140 |   await expect(first).toHaveText("Firstabc");
  141 |   await second.click(); await second.press("End"); await second.press("Enter");
  142 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
```