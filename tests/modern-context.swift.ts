import { test, expect, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { ModernDocument } from "../src/swift-modern.js";
import type {} from "./helpers/modern-surface.js";

async function mount(page: Page, fixture: string) {
  const document = JSON.parse(readFileSync(resolve("docs/acceptance/modern-editor/documents", `${fixture}.json`), "utf8")) as ModernDocument;
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
  const slider = page.getByRole("slider", { name: "Column split" }), box = await slider.boundingBox();
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
