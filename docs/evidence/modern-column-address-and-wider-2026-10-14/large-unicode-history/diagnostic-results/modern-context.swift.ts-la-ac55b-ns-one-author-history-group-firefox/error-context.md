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
  53  |   await info.attach("unicode-history-trace", { body: JSON.stringify(await page.evaluate(() => (window as unknown as { unicodeHistoryTrace: unknown[] }).unicodeHistoryTrace), null, 2), contentType: "application/json" });
  54  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
> 55  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
      |                                                                                            ^ Error: expect(received).toEqual(expected) // deep equality
  56  |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  57  |   await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀");
  58  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  59  | });
  60  | 
  61  | test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  62  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
  63  |     title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  64  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
  65  |     ] });
  66  |   await page.evaluate(() => {
  67  |     const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
  68  |     const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
  69  |     session.markState = (...args) => { counts.marks++; return marks(...args); };
  70  |     session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  71  |   });
  72  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  73  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  74  |   await expect(body).toHaveText("Bold plain!");
  75  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  76  |   await body.evaluate(root => { root.focus(); document.getSelection()!.setBaseAndExtent(root, root.childNodes.length, root, 0); });
  77  |   await page.getByText("Format", { exact: true }).click();
  78  |   const bold = page.getByRole("button", { name: "bold", exact: true });
  79  |   await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  80  |   await page.getByText("Format", { exact: true }).click();
  81  |   await expect(bold).not.toBeVisible();
  82  |   await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  83  |   await page.evaluate(() => {
  84  |     window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
  85  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  86  |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  87  |     peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
  88  |     session.receive(peer.changes());
  89  |   });
  90  |   await expect(body.locator("strong")).toHaveText("Bold plain!");
  91  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  92  |   await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  93  |   await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  94  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  95  |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  96  |   const backward = () => body.evaluate(root => {
  97  |     const selection = document.getSelection()!, a = document.createRange(), b = document.createRange();
  98  |     a.selectNodeContents(root); a.setEnd(selection.anchorNode!, selection.anchorOffset);
  99  |     b.selectNodeContents(root); b.setEnd(selection.focusNode!, selection.focusOffset);
  100 |     return a.toString().length > b.toString().length;
  101 |   });
  102 |   await expect.poll(backward).toBe(true);
  103 |   await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  104 |   await expect(body.locator("strong")).toHaveCount(0);
  105 |   await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  106 |   await expect.poll(backward).toBe(true);
  107 |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  108 |   await page.getByText("Format", { exact: true }).click();
  109 |   await page.getByText("More", { exact: true }).click();
  110 |   const more = page.getByText("More", { exact: true }).locator("..");
  111 |   await more.getByText("Text color: Default", { exact: true }).click();
  112 |   const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  113 |   await ink.getByRole("button", { name: "blue", exact: true }).click();
  114 |   await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
  115 |   expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  116 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  117 | });
  118 | 
  119 | test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  120 |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
  121 |     title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  122 |       { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
  123 |       { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
  124 |     ] });
  125 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  126 |   const outline = page.getByRole("navigation", { name: "Heading outline" });
  127 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  128 |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  129 |   await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  130 |   await page.evaluate(() => {
  131 |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  132 |     const field = peer.field(peer.node({ blockID: "H", path: [] }));
  133 |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  134 |   });
  135 |   await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  136 |   await outline.getByRole("button", { name: "Updated", exact: true }).click();
  137 |   await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  138 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  139 |   await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  140 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  141 | });
  142 | 
  143 | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  144 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  145 |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  146 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  147 |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  148 |     ] };
  149 |   await mount(page, document);
  150 |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  151 |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  152 |   await first.click(); await first.press("End"); await page.keyboard.type("abc");
  153 |   await expect(first).toHaveText("Firstabc");
  154 |   await second.click(); await second.press("End"); await second.press("Enter");
  155 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
```