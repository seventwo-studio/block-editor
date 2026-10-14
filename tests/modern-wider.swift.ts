import { test, expect, type Page } from "@playwright/test";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import type { ModernDocument } from "../src/swift-modern.js";
import type {} from "./helpers/modern-performance.js";

const p95 = (values: number[]) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * .95) - 1];
declare global { interface Window { widerMeasurement?: { result?: { ms: number; frames: number; error?: string }; cleanup(): void } } }
async function frames(page: Page) { await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))); }
async function arm(page: Page, mode: "split" | "selection" | "scroll" | "viewport", expected: number) {
  await page.evaluate(({ mode, expected }) => {
    window.widerMeasurement?.cleanup();
    const source = document.querySelector<HTMLElement>(mode === "split" ? '[data-wider-split]' : mode === "selection" ? '[data-wider-input]' : '.modern-viewport')!;
    const eventName = mode === "viewport" ? "resize" : mode === "scroll" ? "wheel" : "keydown";
    const events = mode === "viewport" ? window : source;
    const previousWidth = document.querySelector<HTMLElement>('.modern-columns > div')!.getBoundingClientRect().width;
    const previousScroll = source.scrollTop;
    const state: NonNullable<Window['widerMeasurement']> = { cleanup: () => events.removeEventListener(eventName, begin, true) };
    function begin(event: Event) {
      if (!event.isTrusted) return;
      state.cleanup(); const start = performance.now(); let count = 0;
      function frame() {
        count++;
        let ready = false;
        if (mode === "viewport") ready = getComputedStyle(document.querySelector('.modern-columns')!).gridTemplateColumns.split(' ').length === expected;
        else if (mode === "split") {
          const layout = window.modernPerformance.session.getSnapshot().document.blocks.find(value => value.id === "group-0-layout");
          ready = layout?.splitBasisPoints === expected && Number((source as HTMLInputElement).value) === expected &&
            Math.abs(document.querySelector<HTMLElement>('.modern-columns > div')!.getBoundingClientRect().width - previousWidth) > 1;
        } else if (mode === "selection") {
          const selection = document.getSelection(), local = window.modernPerformance.session.localSelection();
          const range = local?.selection && "text" in local.selection ? local.selection.text._0 : undefined;
          ready = !!selection && !selection.isCollapsed && (selection.toString().length > expected) && !!range &&
            Math.abs(window.modernPerformance.session.resolvePosition(range.start).offset - window.modernPerformance.session.resolvePosition(range.end).offset) === selection.toString().length;
        } else ready = Math.abs(source.scrollTop - previousScroll) > 1;
        if (count >= 2 && ready) state.result = { ms: performance.now() - start, frames: count };
        else if (performance.now() - start > 30_000) state.result = { ms: performance.now() - start, frames: count, error: `${mode} did not settle` };
        else requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    }
    events.addEventListener(eventName, begin, true); window.widerMeasurement = state;
  }, { mode, expected });
}
async function measurement(page: Page) {
  await expect.poll(() => page.evaluate(() => !!window.widerMeasurement?.result), { timeout: 45_000 }).toBe(true);
  const result = await page.evaluate(() => window.widerMeasurement!.result!); expect(result.error).toBeUndefined(); return result.ms;
}

// Baselines and independent content/lifetime assertions. No new timing budget.
test("mixed columns reflow, selection, scrolling, media lifetime and 5001-block preservation", async ({ page, browser }, info) => {
  const original = readFileSync('benchmarks/modern-surface-1000.json'), wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? 'dist/block-editor.wasm');
  const fixtureDocument = JSON.parse(original.toString()) as ModernDocument;
  const wide: ModernDocument = { ...fixtureDocument, appearance: { ...fixtureDocument.appearance, pageWidth: 'wide' } };
  const output = process.env.MODERN_WIDER_OUTPUT ?? '.build/finishing/20261014/wider-browser'; mkdirSync(output, { recursive: true });
  const report: Record<string, unknown> = { complete: false, sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
    sourceClean: !execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim(), originalFixtureSHA256: createHash('sha256').update(original).digest('hex'),
    derivedWideFixtureSHA256: createHash('sha256').update(JSON.stringify(wide)).digest('hex'), wasmSHA256: createHash('sha256').update(wasm).digest('hex'),
    browser: info.project.name, browserVersion: browser.version(), warmups: 3, repetitions: 20, newTimingTargets: null,
    qualification: 'Observed viewport-change/native keydown/wheel to verified content/layout and second frame; conservative presented-frame proxy. Controlled tiny images and owned URL lifetime, not production asset throughput or full heap/device acceptance. Wider timing budgets remain unapproved; resize has no invented threshold.' };
  const publish = () => writeFileSync(resolve(output, `${info.project.name}.json`), JSON.stringify(report, null, 2) + '\n');
  const pageErrors: string[] = []; page.on('pageerror', e => { pageErrors.push(String(e)); });
  try {
    await page.route('**/modern-engine.wasm', route => route.fulfill({ body: wasm, contentType: 'application/wasm' }));
    await page.goto('modern-performance.html');
    const started = Date.now();
    await page.evaluate(async encoded => { await window.mountModernPerformance(JSON.parse(encoded), { controlledImages: true }); }, JSON.stringify(wide));
    await expect(page.getByRole('textbox', { name: 'Document title', exact: true })).toBeVisible({ timeout: 120_000 });
    await expect(page.locator('.modern-media img')).toHaveCount(20);
    await expect.poll(() => page.locator('.modern-media img').evaluateAll(images => images.every(image => (image as HTMLImageElement).complete && (image as HTMLImageElement).naturalWidth === 64))).toBe(true);
    report.controlledMediaMountToDecodedMS = Date.now() - started;
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
    const saved = await page.evaluate(() => window.modernPerformance.session.save());
    const reflow: number[] = [], split: number[] = [], selection: number[] = [], scroll: number[] = [];
    report.samples = { reflowMS: reflow, splitMS: split, selectionMS: selection, scrollMS: scroll };
    for (let i = 0; i < 23; i++) {
      const narrow = i % 2 === 0; await arm(page, 'viewport', narrow ? 1 : 2); await page.setViewportSize({ width: narrow ? 420 : 1280, height: 900 });
      const elapsed = await measurement(page); if (i >= 3) reflow.push(elapsed);
      const dimensions = await page.locator('.modern-viewport').evaluate(root => ({ client: root.clientWidth, scroll: root.scrollWidth }));
      expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.client + 1);
      expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide); publish();
    }
    expect(await page.evaluate(() => window.modernPerformance.session.save())).toEqual(saved);
    await page.setViewportSize({ width: 1280, height: 900 }); await frames(page);
    const slider = page.getByRole('slider', { name: 'Column split', exact: true }).first(); await slider.scrollIntoViewIfNeeded();
    await slider.evaluate(input => input.setAttribute('data-wider-split', ''));
    for (let i = 0; i < 23; i++) {
      const expected = i % 2 ? 1000 : 9000; await arm(page, 'split', expected); await slider.press(i % 2 ? 'Home' : 'End');
      const elapsed = await measurement(page); if (i >= 3) split.push(elapsed); publish();
    }
    const resized: ModernDocument = { ...wide, blocks: wide.blocks.map((block, index) => index ? block : { ...block, splitBasisPoints: 9000 }) };
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(resized);
    for (let i = 0; i < 23; i++) await page.getByRole('button', { name: 'Undo', exact: true }).click();
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
    const body = page.locator('[data-block-type="paragraph"]').filter({ hasText: 'Note 0001.' }).getByRole('textbox', { name: 'Block text', exact: true });
    await body.scrollIntoViewIfNeeded(); await body.evaluate(root => { root.setAttribute('data-wider-input', ''); root.focus(); const range = document.createRange(); range.selectNodeContents(root); range.collapse(false); const s = document.getSelection()!; s.removeAllRanges(); s.addRange(range); });
    for (let i = 0; i < 23; i++) {
      const previous = await page.evaluate(() => document.getSelection()?.toString().length ?? 0); await arm(page, 'selection', previous); await body.press('Shift+ArrowLeft');
      const elapsed = await measurement(page); if (i >= 3) selection.push(elapsed); publish();
    }
    const viewport = page.locator('.modern-viewport'); await viewport.hover(); await viewport.evaluate(root => { root.scrollTop = 0; }); await frames(page);
    for (let i = 0; i < 23; i++) { await arm(page, 'scroll', 0); await page.mouse.wheel(0, 400); const elapsed = await measurement(page); if (i >= 3) scroll.push(elapsed); publish(); }
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
    report.resourcesBeforeClose = await page.evaluate(() => window.modernPerformance.resources);
    expect((report.resourcesBeforeClose as { active: number }).active).toBe(20);
    await page.evaluate(() => { window.widerMeasurement?.cleanup(); delete window.widerMeasurement; window.modernPerformance.dispose(); });
    report.resourcesAfterClose = await page.evaluate(() => window.modernPerformance.resources);
    expect((report.resourcesAfterClose as { active: number }).active).toBe(0);
    expect((report.resourcesAfterClose as { released: number }).released).toBe((report.resourcesAfterClose as { created: number }).created);
    report.responsiveArchiveUnchanged = true;

    const largeBytes = readFileSync('docs/acceptance/modern-editor/documents/migrated-5001.json'), large = JSON.parse(largeBytes.toString()) as ModernDocument;
    report.largeFixtureSHA256 = createHash('sha256').update(largeBytes).digest('hex'); report.largeRoots = large.blocks.length;
    await page.evaluate(async encoded => { await window.mountModernPerformance(JSON.parse(encoded)); }, largeBytes.toString());
    const last = page.getByRole('textbox', { name: 'Block text', exact: true }).last(); await expect(last).toBeVisible({ timeout: 120_000 });
    await last.scrollIntoViewIfNeeded(); await last.click(); await last.press('End'); await page.keyboard.type(' 世界😀');
    const expectedLarge: ModernDocument = { ...large, blocks: large.blocks.map((block, index) => index === large.blocks.length - 1
      ? { ...block, content: [{ type: 'text', text: 'Preserved legacy paragraph 5000 世界😀' }] } : block) };
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedLarge);
    const checkpoint = await page.evaluate(() => window.modernPerformance.session.save());
    await page.evaluate(() => { window.modernPerformance.session.execute({ command: 'undo', arguments: {} }); });
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(large);
    await page.evaluate(() => { window.modernPerformance.session.execute({ command: 'redo', arguments: {} }); });
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedLarge);
    // Reopen through the actual engine, independent of the rendered current state.
    const reopened = await page.evaluate(encoded => {
      const next = window.modernPerformance.runtime.restoreModern(JSON.parse(encoded), 'measurement');
      try { return next.getSnapshot().document; } finally { next.close(); } }, JSON.stringify(checkpoint));
    expect(reopened).toEqual(expectedLarge);
    report.largePreservedEditUndoRedoReopen = true;
    report.summary = { reflowP95MS: p95(reflow), splitP95MS: p95(split), selectionP95MS: p95(selection), scrollP95MS: p95(scroll) };
    report.environment = await page.evaluate(() => ({ userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency, devicePixelRatio, viewport: { width: innerWidth, height: innerHeight } }));
    report.pageErrors = pageErrors; report.errors = await page.evaluate(() => window.modernPerformance.errors); expect(report.errors).toEqual([]); expect(pageErrors).toEqual([]);
    report.complete = true; publish();
  } catch (error) { report.failure = String(error); throw error; }
  finally { report.pageErrors = pageErrors; publish(); await info.attach('wider-browser-baseline', { path: resolve(output, `${info.project.name}.json`), contentType: 'application/json' });
    if (!page.isClosed()) await page.evaluate(() => { window.widerMeasurement?.cleanup(); window.modernPerformance?.dispose(); }); }
});
