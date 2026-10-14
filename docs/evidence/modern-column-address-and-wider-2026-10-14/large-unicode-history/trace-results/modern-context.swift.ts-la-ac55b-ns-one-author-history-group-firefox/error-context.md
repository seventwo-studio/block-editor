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
  34  | declare global { interface Window { contextualReadCounts: { marks: number; semantics: number } } }
  35  | 
  36  | test("large-document Unicode typing remains one author history group", async ({ page }, info) => {
  37  |   const document = await mount(page, "migrated-5001");
  38  |   await page.evaluate(() => {
  39  |     const session = window.modernAcceptance.session, trace: unknown[] = [];
  40  |     (window as unknown as { unicodeHistoryTrace: unknown[] }).unicodeHistoryTrace = trace;
  41  |     const execute = session.execute.bind(session), set = session.setLocalSelection.bind(session), end = session.endTypingGroup.bind(session);
  42  |     session.execute = command => {
  43  |       const result = execute(command);
  44  |       trace.push({ type: "command", command: command.command, arguments: command.arguments, focus: result.focus, status: result.status });
  45  |       return result;
  46  |     };
  47  |     session.setLocalSelection = selection => { trace.push({ type: "selection", selection }); return set(selection); };
  48  |     session.endTypingGroup = () => { trace.push({ type: "endTypingGroup" }); return end(); };
  49  |   });
  50  |   const body = page.getByRole("textbox", { name: "Block text", exact: true }).last();
  51  |   await body.scrollIntoViewIfNeeded(); await body.click(); await body.press("End"); await page.keyboard.type(" 世界😀");
  52  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀");
  53  |   const tracePath = info.outputPath("unicode-history-trace.json");
  54  |   writeFileSync(tracePath, JSON.stringify(await page.evaluate(() => (window as unknown as { unicodeHistoryTrace: unknown[] }).unicodeHistoryTrace), null, 2));
  55  |   await info.attach("unicode-history-trace", { path: tracePath, contentType: "application/json" });
  56  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
> 57  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
      |                                                                                            ^ Error: expect(received).toEqual(expected) // deep equality
  58  |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  59  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀");
  60  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  61  | });
  62  | 
  63  | test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  64  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
  65  |     title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  66  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
  67  |     ] });
  68  |   await page.evaluate(() => {
  69  |     const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
  70  |     const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
  71  |     session.markState = (...args) => { counts.marks++; return marks(...args); };
  72  |     session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  73  |   });
  74  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  75  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  76  |   await expect(body).toHaveText("Bold plain!");
  77  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  78  |   await body.evaluate(root => { root.focus(); document.getSelection()!.setBaseAndExtent(root, root.childNodes.length, root, 0); });
  79  |   await page.getByText("Format", { exact: true }).click();
  80  |   const bold = page.getByRole("button", { name: "bold", exact: true });
  81  |   await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  82  |   await page.getByText("Format", { exact: true }).click();
  83  |   await expect(bold).not.toBeVisible();
  84  |   await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  85  |   await page.evaluate(() => {
  86  |     window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
  87  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  88  |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  89  |     peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
  90  |     session.receive(peer.changes());
  91  |   });
  92  |   await expect(body.locator("strong")).toHaveText("Bold plain!");
  93  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  94  |   await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  95  |   await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  96  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  97  |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  98  |   const backward = () => body.evaluate(root => {
  99  |     const selection = document.getSelection()!, a = document.createRange(), b = document.createRange();
  100 |     a.selectNodeContents(root); a.setEnd(selection.anchorNode!, selection.anchorOffset);
  101 |     b.selectNodeContents(root); b.setEnd(selection.focusNode!, selection.focusOffset);
  102 |     return a.toString().length > b.toString().length;
  103 |   });
  104 |   await expect.poll(backward).toBe(true);
  105 |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  106 |   await expect(body.locator("strong")).toHaveCount(0);
  107 |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  108 |   await expect.poll(backward).toBe(true);
  109 |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  110 |   await page.getByText("Format", { exact: true }).click();
  111 |   await page.getByText("More", { exact: true }).click();
  112 |   const more = page.getByText("More", { exact: true }).locator("..");
  113 |   await more.getByText("Text color: Default", { exact: true }).click();
  114 |   const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  115 |   await ink.getByRole("button", { name: "blue", exact: true }).click();
  116 |   await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
  117 |   expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  118 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  119 | });
  120 | 
  121 | test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  122 |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
  123 |     title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  124 |       { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
  125 |       { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
  126 |     ] });
  127 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  128 |   const outline = page.getByRole("navigation", { name: "Heading outline" });
  129 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  130 |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  131 |   await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  132 |   await page.evaluate(() => {
  133 |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  134 |     const field = peer.field(peer.node({ blockID: "H", path: [] }));
  135 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  136 |   });
  137 |   await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  138 |   await outline.getByRole("button", { name: "Updated", exact: true }).click();
  139 |   await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  140 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  141 |   await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  142 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  143 | });
  144 | 
  145 | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  146 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  147 |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  148 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  149 |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  150 |     ] };
  151 |   await mount(page, document);
  152 |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  153 |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  154 |   await first.click(); await first.press("End"); await page.keyboard.type("abc");
  155 |   await expect(first).toHaveText("Firstabc");
  156 |   await second.click(); await second.press("End"); await second.press("Enter");
  157 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
```