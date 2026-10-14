# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> column stacking follows page content width and updated text metrics without authoring split
- Location: tests/modern-context.swift.ts:119:0

# Error details

```
Test timeout of 30000ms exceeded.
```

```
Error: selectOption: Test timeout of 30000ms exceeded.
Call log:
  - waiting for getByLabel('fontSize', { exact: true })

```

# Test source

```ts
  27  | });
  28  | 
  29  | const cellActionsDocument: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "cell-actions",
  30  |   title: "Checked cell actions", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  31  |     { id: "T", type: "table", rows: [{ id: "R", cells: [{ id: "C", header: false, content: [{ type: "text", text: "Original 世界😀" }] }] }] }
  32  |   ] };
  33  | 
  34  | async function trackCellCaptures(page: Page) {
  35  |   await page.evaluate(() => {
  36  |     const { session, events } = window.modernAcceptance, capture = session.captureTableTarget.bind(session);
  37  |     session.captureTableTarget = (...args) => { events.push({ type: "table-capture", target: JSON.stringify(args) }); return capture(...args); };
  38  |   });
  39  | }
  40  | async function captureCount(page: Page) { return page.evaluate(() => window.modernAcceptance.events.filter(event => event.type === "table-capture").length); }
  41  | 
  42  | test("cell actions capture on keyboard opening and retain peer text through author Undo", async ({ page }) => {
  43  |   const original = await mount(page, cellActionsDocument); await trackCellCaptures(page);
  44  |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  45  |   expect(await captureCount(page)).toBe(0);
  46  |   const summary = page.locator('summary[aria-label="Cell actions"]'); await summary.focus(); await summary.press("Enter");
  47  |   await expect(page.getByRole("button", { name: "set Header", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  48  |   await page.evaluate(() => {
  49  |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  50  |     const cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] }), field = peer.field(cell);
  51  |     peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 0), arguments: { text: "Peer: " } }); session.receive(peer.changes());
  52  |   });
  53  |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "set Header", exact: true }).click();
  54  |   await expect(page.getByRole("textbox", { name: "Table header", exact: true })).toHaveText("Peer: Original 世界😀");
  55  |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  56  |   const expected = structuredClone(original); ((expected.blocks[0].rows as { cells: { content: { text: string }[] }[] }[])[0].cells[0].content)[0].text = "Peer: Original 世界😀";
  57  |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  58  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  59  | });
  60  | 
  61  | test("open cell actions reject incompatible peer structure without refreshing their captured target", async ({ page }) => {
  62  |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  63  |   await page.locator('summary[aria-label="Cell actions"]').click();
  64  |   await expect(page.getByRole("button", { name: "insert Row", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  65  |   await page.evaluate(() => {
  66  |     const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
  67  |     const table = peer.node({ blockID: "T", path: [] }), row = peer.node({ blockID: "T", path: ["rows", "R"] }), cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] });
  68  |     peer.execute({ command: "tableStructure", target: peer.captureTableTarget(table, row, cell), arguments: { action: "insertColumn", newIDs: ["peer-cell"] } }); session.receive(peer.changes());
  69  |   });
  70  |   const before = await page.evaluate(() => window.modernAcceptance.session.save());
  71  |   expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  72  |   expect(await captureCount(page)).toBe(1);
  73  |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
  74  |   expect(await page.evaluate(() => window.modernAcceptance.errors.length)).toBeGreaterThan(0);
  75  | });
  76  | 
  77  | test("successful cell actions dismiss and reopening captures the updated structure", async ({ page }) => {
  78  |   await mount(page, cellActionsDocument); await trackCellCaptures(page);
  79  |   const summary = page.locator('summary[aria-label="Cell actions"]').first(); await summary.click();
  80  |   await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  81  |   await expect(summary.locator('..')).not.toHaveAttribute("open", "");
  82  |   expect(await captureCount(page)).toBe(1);
  83  |   await summary.focus(); await summary.press("Enter");
  84  |   await page.getByRole("button", { name: "insert Column", exact: true }).first().click();
  85  |   const table = await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0]);
  86  |   expect(table.rows).toHaveLength(2);
  87  |   expect((table.rows as { cells: unknown[] }[]).map(row => row.cells.length)).toEqual([2, 2]);
  88  |   expect(await captureCount(page)).toBe(2);
  89  |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  90  | });
  91  | 
  92  | test("body presentation retains composition through local menus and updates provider status", async ({ page }) => {
  93  |   const original: ModernDocument = { ...cellActionsDocument, documentID: "body-lifecycle", blocks: [
  94  |     { id: "A", type: "paragraph", content: [{ type: "text", text: "Original " }] },
  95  |     { id: "image", type: "image", src: "https://example.test/asset.png", caption: [], width: 64, height: 64 }
  96  |   ] };
  97  |   await mount(page, original);
  98  |   const input = page.getByRole("textbox", { name: "Block text", exact: true }), slider = page.getByRole("slider", { name: "Image width", exact: true });
  99  |   await input.focus(); await input.dispatchEvent("compositionstart");
  100 |   await input.evaluate(root => { root.textContent = "Original 未確定😀"; });
  101 |   await input.dispatchEvent("input", { inputType: "insertCompositionText", isComposing: true });
  102 |   await expect(slider).toBeDisabled();
  103 |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  104 |   await page.getByRole("textbox", { name: "Search blocks" }).press("Escape");
  105 |   await expect(input).toHaveText("Original 未確定😀");
  106 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  107 |   await input.dispatchEvent("compositionend"); await expect(slider).toBeEnabled();
  108 |   await expect(input).toHaveText("Original 未確定😀");
  109 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0].content)).toEqual([{ type: "text", text: "Original 未確定😀" }]);
  110 |   await page.evaluate(() => {
  111 |     const { session } = window.modernAcceptance;
  112 |     const request = session.beginAsyncBlock(session.node({ blockID: "image", path: [] }), "pending-presentation");
  113 |     session.failAsyncBlock(request, "Explicit provider retry remains pending");
  114 |   });
  115 |   await expect(page.locator("figure")).toContainText("Explicit provider retry remains pending");
  116 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  117 | });
  118 | 
  119 | test("column stacking follows page content width and updated text metrics without authoring split", async ({ page }) => {
  120 |   const loaded = JSON.parse(readFileSync(resolve("docs/acceptance/modern-editor/documents/columns-7000.json"), "utf8")) as ModernDocument;
  121 |   const original: ModernDocument = { ...loaded, appearance: { fontFamily: "sans", fontSize: "small", pageWidth: "readable" } };
  122 |   await page.setViewportSize({ width: 1280, height: 900 }); await mount(page, original);
  123 |   const columns = page.locator(".modern-columns"), slider = page.getByRole("slider", { name: "Column split" });
  124 |   const countColumns = () => columns.evaluate(root => getComputedStyle(root).gridTemplateColumns.split(" ").length);
  125 |   await expect.poll(countColumns).toBe(2);
  126 |   await page.getByText("Appearance", { exact: true }).click();
> 127 |   await page.getByLabel("fontSize", { exact: true }).selectOption("large");
      |                                                     ^ Error: selectOption: Test timeout of 30000ms exceeded.
  128 |   await expect.poll(countColumns).toBe(1); await expect(slider).toHaveValue("7000");
  129 |   await page.getByLabel("pageWidth", { exact: true }).selectOption("wide");
  130 |   await expect.poll(countColumns).toBe(2); await expect(slider).toHaveValue("7000");
  131 |   const beforeResize = await page.evaluate(() => window.modernAcceptance.session.save());
  132 |   await page.setViewportSize({ width: 500, height: 900 }); await expect.poll(countColumns).toBe(1);
  133 |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(beforeResize);
  134 |   await expect(slider).toHaveValue("7000");
  135 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  136 | });
  137 | 
  138 | test("keyboard column resize releases its preview before a peer resize", async ({ page }) => {
  139 |   const original = await mount(page, "columns-7000");
  140 |   const slider = page.getByRole("slider", { name: "Column split" });
  141 |   await slider.focus(); await slider.press("ArrowLeft");
  142 |   await expect(slider).toHaveValue("6999");
  143 |   await page.evaluate(() => {
  144 |     const { peer, session } = window.modernAcceptance;
  145 |     peer.receive(session.changes());
  146 |     peer.execute({ command: "resizeColumns", target: { layout: peer.node({ blockID: "layout", path: [] }) }, arguments: { splitBasisPoints: 4000 } });
  147 |     session.receive(peer.changes());
  148 |   });
  149 |   await expect(slider).toHaveValue("4000"); await expect(slider).toBeFocused();
  150 |   const expected = structuredClone(original); (expected.blocks[0] as { splitBasisPoints: number }).splitBasisPoints = 4000;
  151 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  152 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  153 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  154 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  155 | });
  156 | 
  157 | test("Escape cancels a column drag without authoring or changing history", async ({ page }) => {
  158 |   const original = await mount(page, "columns-7000");
  159 |   const slider = page.getByRole("slider", { name: "Column split" }), box = await slider.boundingBox();
  160 |   expect(box).not.toBeNull();
  161 |   const before = await page.evaluate(() => window.modernAcceptance.session.save());
  162 |   await page.mouse.move(box!.x + box!.width * 0.75, box!.y + box!.height / 2); await page.mouse.down();
  163 |   await page.mouse.move(box!.x + box!.width * 0.3, box!.y + box!.height / 2);
  164 |   await expect(slider).not.toHaveValue("7000");
  165 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  166 |   await page.keyboard.press("Escape"); await page.mouse.up();
  167 |   await expect(slider).toHaveValue("7000");
  168 |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
  169 | });
  170 | 
  171 | test("accessible insertion cancellation returns to the original text caret", async ({ page }) => {
  172 |   await mount(page, "columns-7000");
  173 |   const body = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  174 |   await body.focus();
  175 |   for (let i = 0; i < 3; i++) await body.press("ArrowRight");
  176 |   expect(await body.evaluate(element => {
  177 |     const selection = element.ownerDocument.getSelection();
  178 |     const range = element.ownerDocument.createRange(); range.selectNodeContents(element);
  179 |     range.setEnd(selection!.focusNode!, selection!.focusOffset); return range.toString().length;
  180 |   })).toBe(3);
  181 |   await page.getByRole("button", { name: "Insert", exact: true }).click();
  182 |   const search = page.getByRole("textbox", { name: "Search blocks" });
  183 |   await expect(search).toBeFocused(); await search.press("Escape");
  184 |   await expect(page.getByRole("dialog", { name: "Insert block" })).toHaveCount(0);
  185 |   await expect(body).toBeFocused(); await body.press("!"); await expect(body).toHaveText("ABC!");
  186 | });
  187 | 
  188 | test("Escape dismisses the Link action and retains its captured input", async ({ page }) => {
  189 |   const original = await mount(page, "columns-7000");
  190 |   const body = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  191 |   await body.focus(); await body.press("End");
  192 |   await page.getByRole("button", { name: "Link", exact: true }).click();
  193 |   const url = page.getByRole("textbox", { name: "Link URL" });
  194 |   await url.fill("https://example.org"); await url.press("Escape");
  195 |   await expect(page.getByRole("dialog", { name: "Link", exact: true })).toHaveCount(0);
  196 |   await expect(body).toBeFocused();
  197 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  198 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().canUndo)).toBe(false);
  199 | });
  200 | 
  201 | test("contextual reads preserve opaque metadata named like schema collections", async ({ page }) => {
  202 |   const original: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "opaque-bindings", title: "Bindings",
  203 |     appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
  204 |       { id: "opaque", type: "consumer-card", rows: [{ id: "foreign-row", cells: [{ id: "foreign-cell", keep: "opaque 世界😀" }] }],
  205 |         children: [{ id: "unrelated", type: "heading", content: [{ type: "text", text: "Consumer heading" }], keep: "consumer data" }] },
  206 |       { id: "A", type: "paragraph", content: [{ type: "text", text: "ABC", marks: [] }] }
  207 |     ] };
  208 |   await mount(page, original);
  209 |   const body = page.getByRole("textbox", { name: "Block text", exact: true });
  210 |   const saved = await page.evaluate(() => window.modernAcceptance.session.save());
  211 |   await page.getByRole("button", { name: "Outline", exact: true }).click();
  212 |   await expect(page.getByRole("navigation", { name: "Heading outline" })).toHaveCount(1);
  213 |   await expect(page.getByRole("navigation", { name: "Heading outline" }).getByRole("button")).toHaveCount(0);
  214 |   await expect(body).toBeVisible();
  215 |   expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(saved);
  216 |   await body.focus(); await body.evaluate(root => { const selection = document.getSelection()!; selection.setBaseAndExtent(root.firstChild!, 0, root.firstChild!, 3); });
  217 |   await page.getByText("Format", { exact: true }).click(); await page.getByRole("button", { name: "bold", exact: true }).click();
  218 |   await expect(body.locator("strong")).toHaveText("ABC");
  219 |   const expected = structuredClone(original); (expected.blocks[1].content as { marks: { type: string }[] }[])[0].marks = [{ type: "bold" }];
  220 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  221 |   await page.getByRole("button", { name: "Undo", exact: true }).click();
  222 |   expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  223 |   expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
  224 | });
  225 | 
  226 | test("peer deletion and same-label insertion replace contextual bindings before author Undo", async ({ page }) => {
  227 |   const original: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "reused-bindings", title: "Bindings",
```