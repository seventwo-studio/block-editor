import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { ModernDocument } from "../src/swift-modern.js";
import type {} from "./helpers/modern-surface.js";

async function mount(page: Page, fixture: string | ModernDocument) {
  const document = typeof fixture === "string" ? JSON.parse(readFileSync(resolve("docs/acceptance/modern-editor/documents", `${fixture}.json`), "utf8")) as ModernDocument : fixture;
  await page.route("**/modern-engine.wasm", route => route.fulfill({ path: resolve(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm"), contentType: "application/wasm" }));
  await page.goto(`/block-editor/@fs${process.cwd()}/tests/helpers/modern-surface.html`);
  await page.evaluate(async ({ root, documentJSON }) => {
    const { mountModernSurface } = await import(/* @vite-ignore */ `${root}/tests/helpers/modern-surface.tsx`);
    window.modernAcceptance = await mountModernSurface(JSON.parse(documentJSON));
  }, { root: `/block-editor/@fs${process.cwd()}`, documentJSON: JSON.stringify(document) });
  await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toBeVisible();
  return document;
}

test.afterEach(async ({ page }, info) => {
  if (info.status !== info.expectedStatus) {
    const state = await page.evaluate(() => window.modernAcceptance ? { document: window.modernAcceptance.session.getSnapshot().document, events: window.modernAcceptance.events, errors: window.modernAcceptance.errors } : undefined);
    await info.attach("original-failed-state", { body: JSON.stringify(state, null, 2), contentType: "application/json" });
    await info.attach("original-failed-dom", { body: await page.content(), contentType: "text/html" });
    await page.screenshot({ path: info.outputPath("original-failed-surface.png"), fullPage: true });
  }
  await page.evaluate(() => window.modernAcceptance?.dispose());
});

const cellActionsDocument: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "cell-actions",
  title: "Checked cell actions", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
    { id: "T", type: "table", rows: [{ id: "R", cells: [{ id: "C", header: false, content: [{ type: "text", text: "Original 世界😀" }] }] }] }
  ] };

declare global { interface Window { contextualReadCounts: { marks: number; semantics: number } } }

test("large-document Unicode composition and adjacent typing retain author history", async ({ page }) => {
  const document = await mount(page, "migrated-5001");
  const body = page.getByRole("textbox", { name: "Block text", exact: true }).last();
  // insertText commits the complete Unicode buffer once. Firefox keyboard.type
  // starts a separate composition per non-ASCII scalar, a deliberate boundary.
  await body.scrollIntoViewIfNeeded(); await body.click(); await body.press("End");
  await page.keyboard.insertText(" 世界😀"); await page.keyboard.type("abc");
  await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀abc");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  await expect(body).toHaveText("Preserved legacy paragraph 5000 世界😀abc");
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("closed contextual controls defer reads and opening shows current peer formatting and colors", async ({ page }) => {
  await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "contextual-reads",
    title: "Context", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
      { id: "A", type: "paragraph", content: [{ type: "text", text: "Bold", marks: [{ type: "bold" }] }, { type: "text", text: " plain" }] },
    ] });
  await page.evaluate(() => {
    const session = window.modernAcceptance.session, counts = window.contextualReadCounts = { marks: 0, semantics: 0 };
    const marks = session.markState.bind(session), semantics = session.semanticState.bind(session);
    session.markState = (...args) => { counts.marks++; return marks(...args); };
    session.semanticState = (...args) => { counts.semantics++; return semantics(...args); };
  });
  const body = page.getByRole("textbox", { name: "Block text", exact: true });
  await body.click(); await body.press("End"); await page.keyboard.type("!");
  await expect(body).toHaveText("Bold plain!");
  expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  await body.evaluate(root => { root.focus(); document.getSelection()!.setBaseAndExtent(root, root.childNodes.length, root, 0); });
  await page.getByText("Format", { exact: true }).click();
  const bold = page.getByRole("button", { name: "bold", exact: true });
  await expect(bold).toHaveAttribute("aria-pressed", "mixed");
  await page.getByText("Format", { exact: true }).click();
  await expect(bold).not.toBeVisible();
  await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  await page.evaluate(() => {
    window.contextualReadCounts.marks = 0; window.contextualReadCounts.semantics = 0;
    const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
    const field = peer.field(peer.node({ blockID: "A", path: [] }));
    peer.execute({ command: "format", target: { ranges: [peer.captureTextRange(field, 0, peer.text(field).length)] }, arguments: { markType: "bold", mark: { type: "bold" } } });
    session.receive(peer.changes());
  });
  await expect(body.locator("strong")).toHaveText("Bold plain!");
  expect(await page.evaluate(() => window.contextualReadCounts)).toEqual({ marks: 0, semantics: 0 });
  await page.getByText("Format", { exact: true }).click(); await expect(bold).toHaveAttribute("aria-pressed", "true");
  await bold.click(); await expect(body.locator("strong")).toHaveCount(0);
  await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  const backward = () => body.evaluate(root => {
    const selection = document.getSelection()!, a = document.createRange(), b = document.createRange();
    a.selectNodeContents(root); a.setEnd(selection.anchorNode!, selection.anchorOffset);
    b.selectNodeContents(root); b.setEnd(selection.focusNode!, selection.focusOffset);
    return a.toString().length > b.toString().length;
  });
  await expect.poll(backward).toBe(true);
  await body.press(process.platform === "darwin" ? "Meta+Shift+z" : "Control+Shift+z");
  await expect(body.locator("strong")).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => document.getSelection()?.toString())).toBe("Bold plain!");
  await expect.poll(backward).toBe(true);
  await page.getByRole("button", { name: "Undo", exact: true }).click(); await expect(body.locator("strong")).toHaveText("Bold plain!");
  await page.getByText("Format", { exact: true }).click();
  await page.getByText("More", { exact: true }).click();
  const more = page.getByText("More", { exact: true }).locator("..");
  await more.getByText("Text color: Default", { exact: true }).click();
  const ink = more.getByText("Text color: Default", { exact: true }).locator("..");
  await ink.getByRole("button", { name: "blue", exact: true }).click();
  await expect(more.getByText("Text color: blue", { exact: true })).toBeVisible();
  expect((await page.evaluate(() => window.contextualReadCounts)).semantics).toBeGreaterThan(0);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("immutable binding roots keep outline values current after sibling and peer edits", async ({ page }) => {
  await mount(page, { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "root-outline",
    title: "Outline", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
      { id: "H", type: "heading", level: 2, content: [{ type: "text", text: "Original" }] },
      { id: "P", type: "paragraph", content: [{ type: "text", text: "Body" }] },
    ] });
  await page.getByRole("button", { name: "Outline", exact: true }).click();
  const outline = page.getByRole("navigation", { name: "Heading outline" });
  const body = page.getByRole("textbox", { name: "Block text", exact: true });
  await body.click(); await body.press("End"); await page.keyboard.type("!");
  await expect(body).toHaveText("Body!"); await expect(outline.getByRole("button", { name: "Original", exact: true })).toBeVisible();
  await page.evaluate(() => {
    const { session, peer } = window.modernAcceptance; peer.receive(session.changes());
    const field = peer.field(peer.node({ blockID: "H", path: [] }));
    peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 8), arguments: { text: "Updated" } }); session.receive(peer.changes());
  });
  await expect(outline.getByRole("button", { name: "Original", exact: true })).toHaveCount(0);
  await outline.getByRole("button", { name: "Updated", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Heading", exact: true })).toBeFocused();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(body).toHaveText("Body"); await expect(outline.getByRole("button", { name: "Updated", exact: true })).toBeVisible();
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("unchanged sibling commands use current shared state after another block edits", async ({ page }) => {
  const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "retained-sibling",
    title: "Siblings", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
      { id: "A", type: "paragraph", content: [{ type: "text", text: "First" }] },
      { id: "B", type: "paragraph", content: [{ type: "text", text: "Second" }] },
    ] };
  await mount(page, document);
  const first = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  const second = page.getByRole("textbox", { name: "Block text", exact: true }).nth(1);
  await first.click(); await first.press("End"); await page.keyboard.type("abc");
  await expect(first).toHaveText("Firstabc");
  await second.click(); await second.press("End"); await second.press("Enter");
  await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(3);
  await expect(first).toHaveText("Firstabc"); await expect(second).toHaveText("Second");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Block text", exact: true })).toHaveCount(2);
  await expect(first).toHaveText("Firstabc");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("ordinary keyboard typing groups until deliberate caret movement and retains Undo selection", async ({ page }) => {
  const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "keyboard-history",
    title: "History", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
    blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Seed" }] }] };
  await mount(page, document);
  const body = page.getByRole("textbox", { name: "Block text", exact: true });
  await body.click(); await body.press("End"); await page.keyboard.insertText("😀é"); await page.keyboard.type("abc");
  await expect(body).toHaveText("Seed😀éabc");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(body).toHaveText("Seed");
  await expect(body).toBeFocused(); await body.press("ControlOrMeta+Shift+z");
  await expect(body).toHaveText("Seed😀éabc"); await expect(body).toBeFocused();
  await body.press("ArrowLeft"); await page.keyboard.type("XY");
  await expect(body).toHaveText("Seed😀éabXYc");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(body).toHaveText("Seed😀éabc");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(body).toHaveText("Seed");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(document);
});

test("editor actions preserve content without submitting an enclosing host form", async ({ page }) => {
  const document = await mount(page, "unicode");
  await page.evaluate(() => {
    const root = window.document.getElementById("root")!;
    const form = window.document.createElement("form");
    root.parentElement!.insertBefore(form, root); form.append(root);
    form.addEventListener("submit", event => { event.preventDefault(); window.modernAcceptance.events.push({ type: "host-submit", target: "host form" }); });
  });
  await page.getByRole("button", { name: "Insert", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Search blocks", exact: true })).toBeFocused();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Select block", exact: true }).first().click();
  await page.keyboard.press("Escape");
  const state = await page.evaluate(() => ({ submits: window.modernAcceptance.events.filter(event => event.type === "host-submit"), document: window.modernAcceptance.session.getSnapshot().document }));
  expect(state.submits).toEqual([]);
  expect(state.document).toEqual(document);
});

async function trackCellCaptures(page: Page) {
  await page.evaluate(() => {
    const { session, events } = window.modernAcceptance, capture = session.captureTableTarget.bind(session);
    session.captureTableTarget = (...args) => { events.push({ type: "table-capture", target: JSON.stringify(args) }); return capture(...args); };
  });
}
async function captureCount(page: Page) { return page.evaluate(() => window.modernAcceptance.events.filter(event => event.type === "table-capture").length); }

test("cell actions capture on keyboard opening and retain peer text through author Undo", async ({ page }) => {
  const original = await mount(page, cellActionsDocument); await trackCellCaptures(page);
  await page.getByRole("button", { name: "Outline", exact: true }).click();
  expect(await captureCount(page)).toBe(0);
  const summary = page.locator('summary[aria-label="Cell actions"]'); await summary.focus(); await summary.press("Enter");
  await expect(page.getByRole("button", { name: "set Header", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  await page.evaluate(() => {
    const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
    const cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] }), field = peer.field(cell);
    peer.execute({ command: "replaceText", target: peer.captureTextRange(field, 0, 0), arguments: { text: "Peer: " } }); session.receive(peer.changes());
  });
  expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "set Header", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Table header", exact: true })).toHaveText("Peer: Original 世界😀");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  const expected = structuredClone(original); ((expected.blocks[0].rows as { cells: { content: { text: string }[] }[] }[])[0].cells[0].content)[0].text = "Peer: Original 世界😀";
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("open cell actions reject incompatible peer structure without refreshing their captured target", async ({ page }) => {
  await mount(page, cellActionsDocument); await trackCellCaptures(page);
  await page.locator('summary[aria-label="Cell actions"]').click();
  await expect(page.getByRole("button", { name: "insert Row", exact: true })).toBeVisible(); expect(await captureCount(page)).toBe(1);
  await page.evaluate(() => {
    const { peer, session } = window.modernAcceptance; peer.receive(session.changes());
    const table = peer.node({ blockID: "T", path: [] }), row = peer.node({ blockID: "T", path: ["rows", "R"] }), cell = peer.node({ blockID: "T", path: ["rows", "R", "cells", "C"] });
    peer.execute({ command: "tableStructure", target: peer.captureTableTarget(table, row, cell), arguments: { action: "insertColumn", newIDs: ["peer-cell"] } }); session.receive(peer.changes());
  });
  const before = await page.evaluate(() => window.modernAcceptance.session.save());
  expect(await captureCount(page)).toBe(1); await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  expect(await captureCount(page)).toBe(1);
  expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
  expect(await page.evaluate(() => window.modernAcceptance.errors.length)).toBeGreaterThan(0);
});

test("successful cell actions dismiss and reopening captures the updated structure", async ({ page }) => {
  await mount(page, cellActionsDocument); await trackCellCaptures(page);
  const summary = page.locator('summary[aria-label="Cell actions"]').first(); await summary.click();
  await page.getByRole("button", { name: "insert Row", exact: true }).first().click();
  await expect(summary.locator('..')).not.toHaveAttribute("open", "");
  expect(await captureCount(page)).toBe(1);
  await summary.focus(); await summary.press("Enter");
  await page.getByRole("button", { name: "insert Column", exact: true }).first().click();
  const table = await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0]);
  expect(table.rows).toHaveLength(2);
  expect((table.rows as { cells: unknown[] }[]).map(row => row.cells.length)).toEqual([2, 2]);
  expect(await captureCount(page)).toBe(2);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("body presentation retains composition through local menus and updates provider status", async ({ page }) => {
  const original: ModernDocument = { ...cellActionsDocument, documentID: "body-lifecycle", blocks: [
    { id: "A", type: "paragraph", content: [{ type: "text", text: "Original " }] },
    { id: "image", type: "image", src: "https://example.test/asset.png", caption: [], width: 64, height: 64 }
  ] };
  await mount(page, original);
  const input = page.getByRole("textbox", { name: "Block text", exact: true }), slider = page.getByRole("slider", { name: "Image width", exact: true });
  await input.focus(); await input.dispatchEvent("compositionstart");
  await input.evaluate(root => { root.textContent = "Original 未確定😀"; });
  await input.dispatchEvent("input", { inputType: "insertCompositionText", isComposing: true });
  await expect(slider).toBeDisabled();
  await page.getByRole("button", { name: "Insert", exact: true }).click();
  await page.getByRole("textbox", { name: "Search blocks" }).press("Escape");
  await expect(input).toHaveText("Original 未確定😀");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  await input.dispatchEvent("compositionend"); await expect(slider).toBeEnabled();
  await expect(input).toHaveText("Original 未確定😀");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0].content)).toEqual([{ type: "text", text: "Original 未確定😀" }]);
  await page.evaluate(() => {
    const { session } = window.modernAcceptance;
    const request = session.beginAsyncBlock(session.node({ blockID: "image", path: [] }), "pending-presentation");
    session.failAsyncBlock(request, "Explicit provider retry remains pending");
  });
  await expect(page.locator("figure")).toContainText("Explicit provider retry remains pending");
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("inline references follow committed host callbacks while retaining the composing native buffer", async ({ page }) => {
  const original: ModernDocument = { ...cellActionsDocument, documentID: "callback-host", blocks: [
    { id: "A", type: "paragraph", content: [{ type: "entity-ref", entityId: "target", entityType: "page", label: "Page target" }] }
  ] };
  await mount(page, original);
  await page.evaluate(() => {
    const host = window.modernAcceptance;
    host.setOpenReference((id, type) => host.events.push({ type: "open:first", target: id, value: type }));
  });
  const reference = page.getByRole("link", { name: "Page target", exact: true }); await reference.click();
  const input = page.getByRole("textbox", { name: "Block text", exact: true });
  await input.dispatchEvent("compositionstart");
  await input.evaluate(root => root.append(document.createTextNode(" Pending😀")));
  await page.evaluate(() => {
    const host = window.modernAcceptance;
    host.setOpenReference((id, type) => host.events.push({ type: "open:second", target: id, value: type }));
  });
  await reference.focus(); await reference.press("Enter");
  expect(await page.evaluate(() => window.modernAcceptance.events.filter(event => event.type.startsWith("open:")))).toEqual([
    { type: "open:first", target: "target", value: "page" }, { type: "open:second", target: "target", value: "page" }
  ]);
  await expect(input).toHaveText("Page target Pending😀");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  await input.dispatchEvent("compositionend");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document.blocks[0].content)).toEqual([
    { type: "entity-ref", entityId: "target", entityType: "page", label: "Page target" }, { type: "text", text: " Pending😀" }
  ]);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("column stacking follows page content width and updated text metrics without authoring split", async ({ page }) => {
  const loaded = JSON.parse(readFileSync(resolve("docs/acceptance/modern-editor/documents/columns-7000.json"), "utf8")) as ModernDocument;
  const original: ModernDocument = { ...loaded, appearance: { fontFamily: "sans", fontSize: "small", pageWidth: "readable" } };
  await page.setViewportSize({ width: 1280, height: 900 }); await mount(page, original);
  const columns = page.locator(".modern-columns"), slider = page.getByRole("slider", { name: "Column split" });
  const countColumns = () => columns.evaluate(root => getComputedStyle(root).gridTemplateColumns.split(" ").length);
  await expect.poll(countColumns).toBe(2);
  await page.getByText("Appearance", { exact: true }).click();
  await page.getByLabel("Text size", { exact: true }).selectOption("large");
  await expect.poll(countColumns).toBe(1); await expect(slider).toHaveValue("7000");
  await page.getByLabel("Page width", { exact: true }).selectOption("wide");
  await expect.poll(countColumns).toBe(2); await expect(slider).toHaveValue("7000");
  const beforeResize = await page.evaluate(() => window.modernAcceptance.session.save());
  await page.setViewportSize({ width: 500, height: 900 }); await expect.poll(countColumns).toBe(1);
  expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(beforeResize);
  await expect(slider).toHaveValue("7000");
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("keyboard column resize releases its preview before a peer resize", async ({ page }) => {
  const original = await mount(page, "columns-7000");
  const slider = page.getByRole("slider", { name: "Column split" });
  await slider.focus(); await slider.press("ArrowLeft");
  await expect(slider).toHaveValue("6999");
  await page.evaluate(() => {
    const { peer, session } = window.modernAcceptance;
    peer.receive(session.changes());
    peer.execute({ command: "resizeColumns", target: { layout: peer.node({ blockID: "layout", path: [] }) }, arguments: { splitBasisPoints: 4000 } });
    session.receive(peer.changes());
  });
  await expect(slider).toHaveValue("4000"); await expect(slider).toBeFocused();
  const expected = structuredClone(original); (expected.blocks[0] as { splitBasisPoints: number }).splitBasisPoints = 4000;
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("Escape cancels a column drag without authoring or changing history", async ({ page }) => {
  const original = await mount(page, "columns-7000");
  const slider = page.getByRole("slider", { name: "Column split" });
  await slider.scrollIntoViewIfNeeded();
  const box = await slider.boundingBox();
  expect(box).not.toBeNull();
  const before = await page.evaluate(() => window.modernAcceptance.session.save());
  await page.mouse.move(box!.x + box!.width * 0.75, box!.y + box!.height / 2); await page.mouse.down();
  await page.mouse.move(box!.x + box!.width * 0.3, box!.y + box!.height / 2);
  await expect(slider).not.toHaveValue("7000");
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  await page.keyboard.press("Escape"); await page.mouse.up();
  await expect(slider).toHaveValue("7000");
  expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(before);
});

test("accessible insertion cancellation returns to the original text caret", async ({ page }) => {
  await mount(page, "columns-7000");
  const body = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  await body.focus();
  for (let i = 0; i < 3; i++) await body.press("ArrowRight");
  expect(await body.evaluate(element => {
    const selection = element.ownerDocument.getSelection();
    const range = element.ownerDocument.createRange(); range.selectNodeContents(element);
    range.setEnd(selection!.focusNode!, selection!.focusOffset); return range.toString().length;
  })).toBe(3);
  await page.getByRole("button", { name: "Insert", exact: true }).click();
  const search = page.getByRole("textbox", { name: "Search blocks" });
  await expect(search).toBeFocused(); await search.press("Escape");
  await expect(page.getByRole("dialog", { name: "Insert block" })).toHaveCount(0);
  await expect(body).toBeFocused(); await body.press("!"); await expect(body).toHaveText("ABC!");
});

test("Escape dismisses the Link action and retains its captured input", async ({ page }) => {
  const original = await mount(page, "columns-7000");
  const body = page.getByRole("textbox", { name: "Block text", exact: true }).first();
  await body.focus(); await body.press("End");
  await page.getByRole("button", { name: "Link", exact: true }).click();
  const url = page.getByRole("textbox", { name: "Link URL" });
  await url.fill("https://example.org"); await url.press("Escape");
  await expect(page.getByRole("dialog", { name: "Link", exact: true })).toHaveCount(0);
  await expect(body).toBeFocused();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().canUndo)).toBe(false);
});

test("contextual reads preserve opaque metadata named like schema collections", async ({ page }) => {
  const original: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "opaque-bindings", title: "Bindings",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
      { id: "opaque", type: "consumer-card", rows: [{ id: "foreign-row", cells: [{ id: "foreign-cell", keep: "opaque 世界😀" }] }],
        children: [{ id: "unrelated", type: "heading", content: [{ type: "text", text: "Consumer heading" }], keep: "consumer data" }] },
      { id: "A", type: "paragraph", content: [{ type: "text", text: "ABC", marks: [] }] }
    ] };
  await mount(page, original);
  const body = page.getByRole("textbox", { name: "Block text", exact: true });
  const saved = await page.evaluate(() => window.modernAcceptance.session.save());
  await page.getByRole("button", { name: "Outline", exact: true }).click();
  await expect(page.getByRole("navigation", { name: "Heading outline" })).toHaveCount(1);
  await expect(page.getByRole("navigation", { name: "Heading outline" }).getByRole("button")).toHaveCount(0);
  await expect(body).toBeVisible();
  expect(await page.evaluate(() => window.modernAcceptance.session.save())).toEqual(saved);
  await body.focus(); await body.evaluate(root => { const selection = document.getSelection()!; selection.setBaseAndExtent(root.firstChild!, 0, root.firstChild!, 3); });
  await page.getByText("Format", { exact: true }).click(); await page.getByRole("button", { name: "bold", exact: true }).click();
  await expect(body.locator("strong")).toHaveText("ABC");
  const expected = structuredClone(original); (expected.blocks[1].content as { marks: { type: string }[] }[])[0].marks = [{ type: "bold" }];
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(expected);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("peer deletion and same-label insertion replace contextual bindings before author Undo", async ({ page }) => {
  const original: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "reused-bindings", title: "Bindings",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [
      { id: "A", type: "paragraph", content: [{ type: "text", text: "Original", marks: [] }] },
      { id: "B", type: "paragraph", content: [{ type: "text", text: "Later", marks: [] }] }
    ] };
  await mount(page, original);
  const before = await page.evaluate(() => window.modernAcceptance.session.node({ blockID: "A", path: [] }));
  await page.evaluate(() => {
    const { peer, session } = window.modernAcceptance;
    const removed = peer.execute({ command: "delete", target: { ranges: [], nodes: peer.captureNodes([peer.node({ blockID: "A", path: [] })]) }, arguments: {} });
    const inserted = peer.execute({ command: "insertBlock", target: peer.captureBoundary({ field: "blocks" }, peer.node({ blockID: "B", path: [] })),
      arguments: { block: { id: "A", type: "paragraph", content: [{ type: "text", text: "Replacement", marks: [] }] } } });
    if (removed.status !== "applied" || inserted.status !== "applied") throw new Error("Independent peer fixture did not apply");
    session.receive(peer.changes());
  });
  const replaced: ModernDocument = { ...original, blocks: [original.blocks[1], { id: "A", type: "paragraph", content: [{ type: "text", text: "Replacement", marks: [] }] }] };
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(replaced);
  expect(await page.evaluate(() => window.modernAcceptance.session.node({ blockID: "A", path: [] }))).not.toEqual(before);
  const body = page.getByRole("textbox", { name: "Block text", exact: true }).filter({ hasText: "Replacement" });
  await body.focus(); await body.evaluate(root => { document.getSelection()!.setBaseAndExtent(root.firstChild!, 0, root.firstChild!, 11); });
  await page.getByText("Format", { exact: true }).click(); await page.getByRole("button", { name: "bold", exact: true }).click();
  await expect(body.locator("strong")).toHaveText("Replacement");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(replaced);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});

test("same-value peer replacement invalidates origins while no-op snapshots preserve document storage", async ({ page }) => {
  const original: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "same-value-bindings", title: "Bindings",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
    blocks: [{ id: "A", type: "paragraph", content: [{ type: "text", text: "Same 😀", marks: [] }] }] };
  await mount(page, original);
  const result = await page.evaluate(() => {
    const { peer, session } = window.modernAcceptance;
    const initial = session.getSnapshot(), origin = session.node({ blockID: "A", path: [] });
    session.endTypingGroup();
    const noopPreserved = session.getSnapshot().document === initial.document;
    const removed = peer.execute({ command: "delete", target: { ranges: [], nodes: peer.captureNodes([peer.node({ blockID: "A", path: [] })]) }, arguments: {} });
    const inserted = peer.execute({ command: "insertBlock", target: peer.captureBoundary(), arguments: { block: initial.document.blocks[0] } });
    if (removed.status !== "applied" || inserted.status !== "applied") throw new Error("Peer replacement did not apply");
    session.receive(peer.changes());
    const changed = session.getSnapshot();
    return { noopPreserved, equalDocumentPreserved: changed.document === initial.document,
      receiptChanged: changed.syncState !== initial.syncState, originChanged: JSON.stringify(session.node({ blockID: "A", path: [] })) !== JSON.stringify(origin) };
  });
  expect(result).toEqual({ noopPreserved: true, equalDocumentPreserved: true, receiptChanged: true, originChanged: true });
  const body = page.getByRole("textbox", { name: "Block text", exact: true });
  await body.focus(); await body.evaluate(root => { document.getSelection()!.setBaseAndExtent(root.firstChild!, 0, root.firstChild!, 7); });
  await page.getByText("Format", { exact: true }).click(); await page.getByRole("button", { name: "bold", exact: true }).click();
  await expect(body.locator("strong")).toHaveText("Same 😀");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  expect(await page.evaluate(() => window.modernAcceptance.session.getSnapshot().document)).toEqual(original);
  expect(await page.evaluate(() => window.modernAcceptance.errors)).toEqual([]);
});
