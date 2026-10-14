# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-wider.swift.ts >> mixed columns reflow, selection, scrolling, media lifetime and 5001-block preservation
- Location: tests/modern-wider.swift.ts:53:0

# Error details

```
Error: expect(received).toBeLessThanOrEqual(expected)

Expected: <= 421
Received:    2897
```

# Test source

```ts
  1   | import { test, expect, type Page } from "@playwright/test";
  2   | import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
  3   | import { createHash } from "node:crypto";
  4   | import { execFileSync } from "node:child_process";
  5   | import { resolve } from "node:path";
  6   | import type { ModernDocument } from "../src/swift-modern.js";
  7   | import type {} from "./helpers/modern-performance.js";
  8   | 
  9   | const p95 = (values: number[]) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * .95) - 1];
  10  | declare global { interface Window { widerMeasurement?: { result?: { ms: number; frames: number; error?: string }; cleanup(): void } } }
  11  | async function frames(page: Page) { await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve())))); }
  12  | async function arm(page: Page, mode: "split" | "selection" | "scroll" | "viewport", expected: number) {
  13  |   await page.evaluate(({ mode, expected }) => {
  14  |     window.widerMeasurement?.cleanup();
  15  |     const source = document.querySelector<HTMLElement>(mode === "split" ? '[data-wider-split]' : mode === "selection" ? '[data-wider-input]' : '.modern-viewport')!;
  16  |     const eventName = mode === "viewport" ? "resize" : mode === "scroll" ? "wheel" : "keydown";
  17  |     const events = mode === "viewport" ? window : source;
  18  |     const previousWidth = document.querySelector<HTMLElement>('.modern-columns > div')!.getBoundingClientRect().width;
  19  |     const previousScroll = source.scrollTop;
  20  |     const state: NonNullable<Window['widerMeasurement']> = { cleanup: () => events.removeEventListener(eventName, begin, true) };
  21  |     function begin(event: Event) {
  22  |       if (!event.isTrusted) return;
  23  |       state.cleanup(); const start = performance.now(); let count = 0;
  24  |       function frame() {
  25  |         count++;
  26  |         let ready = false;
  27  |         if (mode === "viewport") ready = getComputedStyle(document.querySelector('.modern-columns')!).gridTemplateColumns.split(' ').length === expected;
  28  |         else if (mode === "split") {
  29  |           const layout = window.modernPerformance.session.getSnapshot().document.blocks.find(value => value.id === "group-0-layout");
  30  |           ready = layout?.splitBasisPoints === expected && Number((source as HTMLInputElement).value) === expected &&
  31  |             Math.abs(document.querySelector<HTMLElement>('.modern-columns > div')!.getBoundingClientRect().width - previousWidth) > 1;
  32  |         } else if (mode === "selection") {
  33  |           const selection = document.getSelection(), local = window.modernPerformance.session.localSelection();
  34  |           const range = local?.selection && "text" in local.selection ? local.selection.text._0 : undefined;
  35  |           ready = !!selection && !selection.isCollapsed && (selection.toString().length > expected) && !!range &&
  36  |             Math.abs(window.modernPerformance.session.resolvePosition(range.start).offset - window.modernPerformance.session.resolvePosition(range.end).offset) === selection.toString().length;
  37  |         } else ready = Math.abs(source.scrollTop - previousScroll) > 1;
  38  |         if (count >= 2 && ready) state.result = { ms: performance.now() - start, frames: count };
  39  |         else if (performance.now() - start > 30_000) state.result = { ms: performance.now() - start, frames: count, error: `${mode} did not settle` };
  40  |         else requestAnimationFrame(frame);
  41  |       }
  42  |       requestAnimationFrame(frame);
  43  |     }
  44  |     events.addEventListener(eventName, begin, true); window.widerMeasurement = state;
  45  |   }, { mode, expected });
  46  | }
  47  | async function measurement(page: Page) {
  48  |   await expect.poll(() => page.evaluate(() => !!window.widerMeasurement?.result), { timeout: 45_000 }).toBe(true);
  49  |   const result = await page.evaluate(() => window.widerMeasurement!.result!); expect(result.error).toBeUndefined(); return result.ms;
  50  | }
  51  | 
  52  | // Baselines and independent content/lifetime assertions. No new timing budget.
  53  | test("mixed columns reflow, selection, scrolling, media lifetime and 5001-block preservation", async ({ page, browser }, info) => {
  54  |   const original = readFileSync('benchmarks/modern-surface-1000.json'), wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? 'dist/block-editor.wasm');
  55  |   const fixtureDocument = JSON.parse(original.toString()) as ModernDocument;
  56  |   const wide: ModernDocument = { ...fixtureDocument, appearance: { ...fixtureDocument.appearance, pageWidth: 'wide' } };
  57  |   const output = process.env.MODERN_WIDER_OUTPUT ?? '.build/finishing/20261014/wider-browser'; mkdirSync(output, { recursive: true });
  58  |   const report: Record<string, unknown> = { complete: false, sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  59  |     sourceClean: !execFileSync('git', ['status', '--porcelain'], { encoding: 'utf8' }).trim(), originalFixtureSHA256: createHash('sha256').update(original).digest('hex'),
  60  |     derivedWideFixtureSHA256: createHash('sha256').update(JSON.stringify(wide)).digest('hex'), wasmSHA256: createHash('sha256').update(wasm).digest('hex'),
  61  |     browser: info.project.name, browserVersion: browser.version(), warmups: 3, repetitions: 20, newTimingTargets: null,
  62  |     qualification: 'Observed viewport-change/native keydown/wheel to verified content/layout and second frame; conservative presented-frame proxy. Controlled tiny images and owned URL lifetime, not production asset throughput or full heap/device acceptance. Wider timing budgets remain unapproved; resize has no invented threshold.' };
  63  |   const publish = () => writeFileSync(resolve(output, `${info.project.name}.json`), JSON.stringify(report, null, 2) + '\n');
  64  |   const pageErrors: string[] = []; page.on('pageerror', e => { pageErrors.push(String(e)); });
  65  |   try {
  66  |     await page.route('**/modern-engine.wasm', route => route.fulfill({ body: wasm, contentType: 'application/wasm' }));
  67  |     await page.goto('modern-performance.html');
  68  |     const started = Date.now();
  69  |     await page.evaluate(async encoded => { await window.mountModernPerformance(JSON.parse(encoded), { controlledImages: true }); }, JSON.stringify(wide));
  70  |     await expect(page.getByRole('textbox', { name: 'Document title', exact: true })).toBeVisible({ timeout: 120_000 });
  71  |     await expect(page.locator('.modern-media img')).toHaveCount(20);
  72  |     await expect.poll(() => page.locator('.modern-media img').evaluateAll(images => images.every(image => (image as HTMLImageElement).complete && (image as HTMLImageElement).naturalWidth === 64))).toBe(true);
  73  |     report.controlledMediaMountToDecodedMS = Date.now() - started;
  74  |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
  75  |     const saved = await page.evaluate(() => window.modernPerformance.session.save());
  76  |     const reflow: number[] = [], split: number[] = [], selection: number[] = [], scroll: number[] = [];
  77  |     report.samples = { reflowMS: reflow, splitMS: split, selectionMS: selection, scrollMS: scroll };
  78  |     for (let i = 0; i < 23; i++) {
  79  |       const narrow = i % 2 === 0; await arm(page, 'viewport', narrow ? 1 : 2); await page.setViewportSize({ width: narrow ? 420 : 1280, height: 900 });
  80  |       const elapsed = await measurement(page); if (i >= 3) reflow.push(elapsed);
  81  |       const dimensions = await page.locator('.modern-viewport').evaluate(root => ({ client: root.clientWidth, scroll: root.scrollWidth }));
> 82  |       expect(dimensions.scroll).toBeLessThanOrEqual(dimensions.client + 1);
      |                                ^ Error: expect(received).toBeLessThanOrEqual(expected)
  83  |       expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide); publish();
  84  |     }
  85  |     expect(await page.evaluate(() => window.modernPerformance.session.save())).toEqual(saved);
  86  |     await page.setViewportSize({ width: 1280, height: 900 }); await frames(page);
  87  |     const slider = page.getByRole('slider', { name: 'Column split', exact: true }).first(); await slider.scrollIntoViewIfNeeded();
  88  |     await slider.evaluate(input => input.setAttribute('data-wider-split', ''));
  89  |     for (let i = 0; i < 23; i++) {
  90  |       const expected = i % 2 ? 1000 : 9000; await arm(page, 'split', expected); await slider.press(i % 2 ? 'Home' : 'End');
  91  |       const elapsed = await measurement(page); if (i >= 3) split.push(elapsed); publish();
  92  |     }
  93  |     const resized: ModernDocument = { ...wide, blocks: wide.blocks.map((block, index) => index ? block : { ...block, splitBasisPoints: 9000 }) };
  94  |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(resized);
  95  |     for (let i = 0; i < 23; i++) await page.getByRole('button', { name: 'Undo', exact: true }).click();
  96  |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
  97  |     const body = page.locator('[data-block-type="paragraph"]').filter({ hasText: 'Note 0001.' }).getByRole('textbox', { name: 'Block text', exact: true });
  98  |     await body.scrollIntoViewIfNeeded(); await body.evaluate(root => { root.setAttribute('data-wider-input', ''); root.focus(); const range = document.createRange(); range.selectNodeContents(root); range.collapse(false); const s = document.getSelection()!; s.removeAllRanges(); s.addRange(range); });
  99  |     for (let i = 0; i < 23; i++) {
  100 |       const previous = await page.evaluate(() => document.getSelection()?.toString().length ?? 0); await arm(page, 'selection', previous); await body.press('Shift+ArrowLeft');
  101 |       const elapsed = await measurement(page); if (i >= 3) selection.push(elapsed); publish();
  102 |     }
  103 |     const viewport = page.locator('.modern-viewport'); await viewport.hover(); await viewport.evaluate(root => { root.scrollTop = 0; }); await frames(page);
  104 |     for (let i = 0; i < 23; i++) { await arm(page, 'scroll', 0); await page.mouse.wheel(0, 400); const elapsed = await measurement(page); if (i >= 3) scroll.push(elapsed); publish(); }
  105 |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(wide);
  106 |     report.resourcesBeforeClose = await page.evaluate(() => window.modernPerformance.resources);
  107 |     expect((report.resourcesBeforeClose as { active: number }).active).toBe(20);
  108 |     await page.evaluate(() => { window.widerMeasurement?.cleanup(); delete window.widerMeasurement; window.modernPerformance.dispose(); });
  109 |     report.resourcesAfterClose = await page.evaluate(() => window.modernPerformance.resources);
  110 |     expect((report.resourcesAfterClose as { active: number }).active).toBe(0);
  111 |     expect((report.resourcesAfterClose as { released: number }).released).toBe((report.resourcesAfterClose as { created: number }).created);
  112 |     report.responsiveArchiveUnchanged = true;
  113 | 
  114 |     const largeBytes = readFileSync('docs/acceptance/modern-editor/documents/migrated-5001.json'), large = JSON.parse(largeBytes.toString()) as ModernDocument;
  115 |     report.largeFixtureSHA256 = createHash('sha256').update(largeBytes).digest('hex'); report.largeRoots = large.blocks.length;
  116 |     await page.evaluate(async encoded => { await window.mountModernPerformance(JSON.parse(encoded)); }, largeBytes.toString());
  117 |     const last = page.getByRole('textbox', { name: 'Block text', exact: true }).last(); await expect(last).toBeVisible({ timeout: 120_000 });
  118 |     await last.scrollIntoViewIfNeeded(); await last.click(); await last.press('End'); await page.keyboard.type(' 世界😀');
  119 |     const expectedLarge: ModernDocument = { ...large, blocks: large.blocks.map((block, index) => index === large.blocks.length - 1
  120 |       ? { ...block, content: [{ type: 'text', text: 'Preserved legacy paragraph 5000 世界😀' }] } : block) };
  121 |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedLarge);
  122 |     const checkpoint = await page.evaluate(() => window.modernPerformance.session.save());
  123 |     await page.evaluate(() => { window.modernPerformance.session.execute({ command: 'undo', arguments: {} }); });
  124 |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(large);
  125 |     await page.evaluate(() => { window.modernPerformance.session.execute({ command: 'redo', arguments: {} }); });
  126 |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedLarge);
  127 |     // Reopen through the actual engine, independent of the rendered current state.
  128 |     const reopened = await page.evaluate(encoded => {
  129 |       const next = window.modernPerformance.runtime.restoreModern(JSON.parse(encoded), 'measurement');
  130 |       try { return next.getSnapshot().document; } finally { next.close(); } }, JSON.stringify(checkpoint));
  131 |     expect(reopened).toEqual(expectedLarge);
  132 |     report.largePreservedEditUndoRedoReopen = true;
  133 |     report.summary = { reflowP95MS: p95(reflow), splitP95MS: p95(split), selectionP95MS: p95(selection), scrollP95MS: p95(scroll) };
  134 |     report.environment = await page.evaluate(() => ({ userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency, devicePixelRatio, viewport: { width: innerWidth, height: innerHeight } }));
  135 |     report.pageErrors = pageErrors; report.errors = await page.evaluate(() => window.modernPerformance.errors); expect(report.errors).toEqual([]); expect(pageErrors).toEqual([]);
  136 |     report.complete = true; publish();
  137 |   } catch (error) { report.failure = String(error); throw error; }
  138 |   finally { report.pageErrors = pageErrors; publish(); await info.attach('wider-browser-baseline', { path: resolve(output, `${info.project.name}.json`), contentType: 'application/json' });
  139 |     if (!page.isClosed()) await page.evaluate(() => { window.widerMeasurement?.cleanup(); window.modernPerformance?.dispose(); }); }
  140 | });
  141 | 
```