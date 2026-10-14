# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-performance.swift.ts >> production modern surface measures original input and menu response on 1000 mixed blocks
- Location: tests/modern-performance.swift.ts:42:0

# Error details

```
Error: 1,000-block edit-to-display p95 must meet 50 ms

expect(received).toBeLessThanOrEqual(expected)

Expected: <= 50
Received:    53
```

# Test source

```ts
  1   | import { test, expect, type Page } from "@playwright/test";
  2   | import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
  3   | import { createHash } from "node:crypto";
  4   | import { resolve } from "node:path";
  5   | import { execFileSync } from "node:child_process";
  6   | import type { ModernDocument } from "../src/swift-modern.js";
  7   | import type {} from "./helpers/modern-performance.js";
  8   | 
  9   | const percentile = (values: number[], fraction: number) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * fraction) - 1];
  10  | async function arm(page: Page, mode: "input" | "menu", expected: string) {
  11  |   await page.evaluate(({ mode, expected }) => {
  12  |     window.modernMeasurement?.cleanup();
  13  |     const source = mode === "input" ? window.document.querySelector<HTMLElement>('[data-measurement-input]')! :
  14  |       Array.from(window.document.querySelectorAll<HTMLButtonElement>("button")).find(button => button.textContent === "Insert")!;
  15  |     const type = mode === "input" ? "keydown" : "pointerdown";
  16  |     const state: NonNullable<Window["modernMeasurement"]> = { armed: true, cleanup: () => source.removeEventListener(type, begin, true) };
  17  |     function begin(event: Event) {
  18  |       if (!event.isTrusted || (mode === "input" && (!(event instanceof KeyboardEvent) || event.key !== "!"))) return;
  19  |       const start = performance.now(); let frames = 0;
  20  |       state.cleanup(); state.armed = false;
  21  |       function frame() {
  22  |         frames++;
  23  |         const accepted = mode === "input" ? window.modernPerformance.session.getSnapshot().document.blocks.some(block =>
  24  |           block.id === "note-1" && Array.isArray(block.content) && block.content.map(node => typeof node === "object" && node && "text" in node ? node.text : "").join("") === expected) : true;
  25  |         const displayed = mode === "input" ? source.textContent === expected :
  26  |           !!window.document.querySelector('[role="dialog"][aria-label="Insert block"]') && window.document.activeElement?.getAttribute("aria-label") === "Search blocks";
  27  |         if (accepted && displayed && frames >= 2) state.result = { elapsedMS: performance.now() - start, frameCount: frames };
  28  |         else if (!(accepted && displayed) && performance.now() - start > 30_000) state.result = { elapsedMS: performance.now() - start, frameCount: frames,
  29  |           accepted, displayed, nativeBuffer: source.textContent ?? "", error: "Accepted content and rendered/focused surface did not settle" };
  30  |         else requestAnimationFrame(frame);
  31  |       }
  32  |       requestAnimationFrame(frame);
  33  |     }
  34  |     source.addEventListener(type, begin, true); window.modernMeasurement = state;
  35  |   }, { mode, expected });
  36  | }
  37  | async function result(page: Page) {
  38  |   await expect.poll(() => page.evaluate(() => !!window.modernMeasurement?.result), { timeout: 45_000 }).toBe(true);
  39  |   const value = await page.evaluate(() => window.modernMeasurement!.result!); expect(value.error).toBeUndefined(); return value.elapsedMS;
  40  | }
  41  | 
  42  | test("production modern surface measures original input and menu response on 1000 mixed blocks", async ({ page, browser }, info) => {
  43  |   const fixture = readFileSync("benchmarks/modern-surface-1000.json"), document = JSON.parse(fixture.toString()) as ModernDocument;
  44  |   const wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm");
  45  |   const output = process.env.MODERN_PERFORMANCE_OUTPUT ?? ".build/finishing/20261014/modern-performance";
  46  |   mkdirSync(output, { recursive: true });
  47  |   const report: Record<string, unknown> = { complete: false, sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  48  |     sourceClean: !execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim(), fixtureSHA256: createHash("sha256").update(fixture).digest("hex"),
  49  |     wasmSHA256: createHash("sha256").update(wasm).digest("hex"), browser: info.project.name, browserVersion: browser.version(),
  50  |     warmups: 3, repetitions: 20, inputMS: [], menuMS: [], productionReact: true,
  51  |     method: "Trusted native initiating keydown/pointerdown to the second animation frame with accepted text and rendered content/menu focus verified; conservative presented-frame proxy, includes at least one frame opportunity and keydown validation. Sequential warmups excluded. No network/disk-cold startup or physical input/assistive acceptance claim." };
  52  |   report.diagnostic = process.env.MODERN_SURFACE_DIAGNOSTIC === "1";
  53  |   const consoleMessages: string[] = [], pageErrors: string[] = [];
  54  |   const publish = () => writeFileSync(resolve(output, `${info.project.name}.json`), JSON.stringify(report, null, 2) + "\n");
  55  |   page.on("console", message => { if (consoleMessages.length < 200) consoleMessages.push(message.text()); report.consoleMessages = consoleMessages; publish(); });
  56  |   page.on("pageerror", error => { pageErrors.push(String(error)); report.pageErrors = pageErrors; publish(); });
  57  |   try {
  58  |     await page.route("**/modern-engine.wasm", route => route.fulfill({ body: wasm, contentType: "application/wasm" }));
  59  |     await page.goto("modern-performance.html");
  60  |     await page.evaluate(async ({ encoded, diagnostic }) => { window.modernPerformanceDiagnostic = diagnostic; await window.mountModernPerformance(JSON.parse(encoded)); },
  61  |       { encoded: fixture.toString(), diagnostic: process.env.MODERN_SURFACE_DIAGNOSTIC === "1" });
  62  |     await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toBeVisible({ timeout: 120_000 });
  63  |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(document);
  64  |     const body = page.locator('[data-block-type="paragraph"]').filter({ hasText: "Note 0001." }).getByRole("textbox", { name: "Block text", exact: true });
  65  |     await body.evaluate(element => { element.setAttribute("data-measurement-input", ""); element.focus(); const range = window.document.createRange(); range.selectNodeContents(element); range.collapse(false); const selection = window.document.getSelection()!; selection.removeAllRanges(); selection.addRange(range); });
  66  |     await expect(body).toBeFocused();
  67  |     await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  68  |     let expected = (document.blocks.find(block => block.id === "note-1")!.content as { text: string }[]).map(node => node.text).join("");
  69  |     const input: number[] = [], menu: number[] = [];
  70  |     for (let i = 0; i < 23; i++) {
  71  |       expected += "!"; await arm(page, "input", expected); await page.keyboard.press("!"); const elapsed = await result(page);
  72  |       if (i >= 3) input.push(elapsed); report.inputMS = input; publish();
  73  |     }
  74  |     const saved = await page.evaluate(() => window.modernPerformance.session.save());
  75  |     for (let i = 0; i < 23; i++) {
  76  |       await arm(page, "menu", ""); await page.getByRole("button", { name: "Insert", exact: true }).click(); const elapsed = await result(page);
  77  |       if (i >= 3) menu.push(elapsed); report.menuMS = menu; publish();
  78  |       await page.getByRole("textbox", { name: "Search blocks" }).press("Escape");
  79  |       await expect(body).toBeFocused();
  80  |     }
  81  |     expect(await page.evaluate(() => window.modernPerformance.session.save())).toEqual(saved);
  82  |     const expectedDocument = structuredClone(document); (expectedDocument.blocks.find(block => block.id === "note-1")!.content as { text: string }[])[0].text = expected;
  83  |     expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedDocument);
  84  |     report.environment = await page.evaluate(() => ({ userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency, viewport: { width: innerWidth, height: innerHeight }, devicePixelRatio }));
  85  |     const inputP95MS = percentile(input, .95), menuP95MS = percentile(menu, .95);
  86  |     report.summary = { inputP95MS, menuP95MS, targets: { inputP95MS: 50, menuP95MS: 100 } };
  87  |     report.targetsPassed = inputP95MS <= 50 && menuP95MS <= 100;
  88  |     report.complete = true;
  89  |     await page.screenshot({ path: info.outputPath("mixed-surface.png") });
  90  |     // Completing measurement is distinct from meeting the accepted budgets.
  91  |     // Retain all samples and finish with failure when either target is missed.
> 92  |     expect.soft(inputP95MS, "1,000-block edit-to-display p95 must meet 50 ms").toBeLessThanOrEqual(50);
      |                                                                               ^ Error: 1,000-block edit-to-display p95 must meet 50 ms
  93  |     expect.soft(menuP95MS, "1,000-block menu p95 must meet 100 ms").toBeLessThanOrEqual(100);
  94  |   } catch (error) { report.error = String(error); throw error; }
  95  |   finally {
  96  |     report.consoleMessages = consoleMessages; report.pageErrors = pageErrors;
  97  |     if (!page.isClosed()) {
  98  |       try { report.lastState = await page.evaluate(() => ({ accepted: window.modernPerformance?.session.getSnapshot().document.blocks.find(block => block.id === "note-1"),
  99  |         nativeBuffer: window.document.querySelector('[data-measurement-input]')?.textContent, focused: window.document.activeElement?.getAttribute("aria-label"),
  100 |         measurement: window.modernMeasurement?.result, errors: window.modernPerformance?.errors })); }
  101 |       catch (error) { report.stateCaptureError = String(error); }
  102 |     }
  103 |     publish(); await info.attach("modern-surface-performance", { path: resolve(output, `${info.project.name}.json`), contentType: "application/json" });
  104 |     if (!page.isClosed()) { try { await page.evaluate(() => window.modernPerformance?.dispose()); } catch (error) { report.cleanupError = String(error); publish(); } }
  105 |   }
  106 | });
  107 | 
```