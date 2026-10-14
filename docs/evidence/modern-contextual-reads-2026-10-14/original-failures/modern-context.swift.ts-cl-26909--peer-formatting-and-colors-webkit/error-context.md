# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> closed contextual controls defer reads and opening shows current peer formatting and colors
- Location: tests/modern-context.swift.ts:36:0

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByText('More', { exact: true }).locator('..').getByText('Text color: blue', { exact: true })
Expected: visible
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" getByText('More', { exact: true }).locator('..').getByText('Text color: blue', { exact: true }) with timeout 5000ms
  - waiting for getByText('More', { exact: true }).locator('..').getByText('Text color: blue', { exact: true })

```

```yaml
- button "Outline"
- button "Focus"
- group: Appearance
- textbox "Document title"
- button "Select block": ⋮⋮
- textbox "Block text":
  - strong: Bold plain!
- toolbar "Editing actions":
  - button "Insert"
  - group: Format
  - button "Link"
  - button "Undo"
  - group:
    - text: More
    - button "Redo"
    - button "Select block"
    - group:
      - text: "Text color: Default"
      - button "neutral"
      - button "green"
      - button "blue"
      - button "purple"
      - button "amber"
      - button "red"
      - button "reset" [pressed]
    - group: "Background: Default"
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
  36  | test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  37  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
  38  |     title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  39  |       { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
  40  |     ] });
  41  |   await page.evaluate(() => {
  42  |     const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
  43  |     const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
  44  |     session.markState = (...args) => { counts.marks++; return marks(...args); };
  45  |     session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  46  |   });
  47  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  48  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  49  |   await expect(body).toHaveText("Bold plain!");
  50  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  51  |   await body.evaluate(root => { root.focus(); const range = document.createRange(); range.selectNodeContents(root); const selection = document.getSelection()!; selection.removeAllRanges(); selection.addRange(range); });
  52  |   await page.getByText("Format", { exact: true }).click();
  53  |   const bold = page.getByRole("button", { name: "bold", exact: true });
  54  |   await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  55  |   await page.getByText("Format", { exact: true }).click();
  56  |   await page.evaluate(() => {
  57  |     window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
  58  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  59  |     const field = peer.field(peer.node({ blockID: "A", path: [] }));
  60  |     peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
  61  |     session.receive(peer.changes());
  62  |   });
  63  |   await expect(body.locator("strong")).toHaveText("Bold plain!");
  64  |   expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  65  |   await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  66  |   await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  67  |   await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  68  |   await page.getByText("Format", { exact: true }).click();
  69  |   await page.getByText("More", { exact: true }).click();
  70  |   const more = page.getByText("More", { exact: true }).locator("..");
  71  |   await more.getByText("Text color: Default", { exact: true }).click();
  72  |   const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  73  |   await ink.getByRole("button", { name: "blue", exact: true }).click();
> 74  |   await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
      |                                                                    ^ Error: expect(locator).toBeVisible() failed
  75  |   expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  76  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  77  | });
  78  | 
  79  | test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  80  |   await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
  81  |     title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  82  |       { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
  83  |       { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
  84  |     ] });
  85  |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  86  |   const outline = page.getByRole("navigation", { name: "Heading outline" });
  87  |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  88  |   await body.click(); await body.press("End"); await page.keyboard.type("!");
  89  |   await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  90  |   await page.evaluate(() => {
  91  |     const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
  92  |     const field = peer.field(peer.node({ blockID: "H", path: [] }));
  93  |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  94  |   });
  95  |   await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  96  |   await outline.getByRole("button", { name: "Updated", exact: true }).click();
  97  |   await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  98  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  99  |   await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  100 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  101 | });
  102 | 
  103 | test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  104 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
  105 |     title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  106 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
  107 |       { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
  108 |     ] };
  109 |   await mount(page, document);
  110 |   const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  111 |   const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  112 |   await first.click(); await first.press("End"); await page.keyboard.type("abc");
  113 |   await expect(first).toHaveText("Firstabc");
  114 |   await second.click(); await second.press("End"); await second.press("Enter");
  115 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
  116 |   await expect(first).toHaveText("Firstabc"); await expect(second).toHaveText("Second");
  117 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  118 |   await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(2);
  119 |   await expect(first).toHaveText("Firstabc");
  120 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  121 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  122 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  123 | });
  124 | 
  125 | test("ordinary keyboard typing groups until deliberate caret movement and retains Undo selection", async ({ page }) => {
  126 |   const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "keyboard-history",
  127 |     title: "History", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
  128 |     blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Seed" }] }] };
  129 |   await mount(page, document);
  130 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  131 |   await body.click(); await body.press("End"); await page.keyboard.insertText("😀é"); await page.keyboard.type("abc");
  132 |   await expect(body).toHaveText("Seed😀éabc");
  133 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  134 |   await expect(body).toHaveText("Seed");
  135 |   await expect(body).toBeFocused(); await body.press("ControlOrMeta+Shift+z");
  136 |   await expect(body).toHaveText("Seed😀éabc"); await expect(body).toBeFocused();
  137 |   await body.press("ArrowLeft"); await page.keyboard.type("XY");
  138 |   await expect(body).toHaveText("Seed😀éabXYc");
  139 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  140 |   await expect(body).toHaveText("Seed😀éabc");
  141 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  142 |   await expect(body).toHaveText("Seed");
  143 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  144 | });
  145 | 
  146 | test("editor actions preserve content without submitting an enclosing host form", async ({ page }) => {
  147 |   const document = await mount(page, "unicode");
  148 |   await page.evaluate(() => {
  149 |     const root = window.document.getElementById("root")!;
  150 |     const form = window.document.createElement("form");
  151 |     root.parentElement!.insertBefore(form, root); form.append(root);
  152 |     form.addEventListener("submit", event => { event.preventDefault(); window.modernAcceptance.events.push({ type: "host-submit", target: "host form" }); });
  153 |   });
  154 |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  155 |   await expect(page.getByRole("textbox", { name: "Search blocks", exact: true })).toBeFocused();
  156 |   await page.keyboard.press("Escape");
  157 |   await page.getByRole("button", { name: "Select block", exact: true }).first().click();
  158 |   await page.keyboard.press("Escape");
  159 |   const state = await page.evaluate(() => ({ submits: window.modernAcceptance.events.filter(event => event.type === "host-submit"), document: window.modernAcceptance.session.getSnapshot().document }));
  160 |   expect(state.submits).toEqual([]);
  161 |   expect(state.document).toEqual(document);
  162 | });
  163 | 
  164 | async function trackCellCaptures(page: Page) {
  165 |   await page.evaluate(() => {
  166 |     const { session, events } = window.modernAcceptance, capture = session.captureTableTarget.bind(session);
  167 |     session.captureTableTarget = (...args) => { events.push({ type: "table-capture", target: JSON.stringify(args) }); return capture(...args); };
  168 |   });
  169 | }
  170 | async function captureCount(page: Page) { return page.evaluate(() => window.modernAcceptance.events.filter(event => event.type === "table-capture").length); }
  171 | 
  172 | test("cell actions capture on keyboard opening and retain peer text through author Undo", async ({ page }) => {
  173 |   const original = await mount(page, cellActionsDocument); await trackCellCaptures(page);
  174 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
```