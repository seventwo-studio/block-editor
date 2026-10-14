import { test, expect, type Page } from "@playwright/test";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
import type { ModernDocument } from "../src/swift-modern.js";
import type {} from "./helpers/modern-performance.js";

const percentile = (values: number[], fraction: number) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * fraction) - 1];
async function arm(page: Page, mode: "input" | "menu", expected: string) {
  await page.evaluate(({ mode, expected }) => {
    window.modernMeasurement?.cleanup();
    const source = mode === "input" ? window.document.querySelector<HTMLElement>('[data-measurement-input]')! :
      Array.from(window.document.querySelectorAll<HTMLButtonElement>("button")).find(button => button.textContent === "Insert")!;
    const type = mode === "input" ? "beforeinput" : "pointerdown";
    const state: NonNullable<Window["modernMeasurement"]> = { armed: true, cleanup: () => source.removeEventListener(type, begin, true) };
    function begin() {
      const start = performance.now(); let frames = 0;
      state.cleanup(); state.armed = false;
      function frame() {
        frames++;
        const accepted = mode === "input" ? window.modernPerformance.session.getSnapshot().document.blocks.some(block =>
          block.id === "note-1" && Array.isArray(block.content) && block.content.map(node => typeof node === "object" && node && "text" in node ? node.text : "").join("") === expected) : true;
        const displayed = mode === "input" ? source.textContent === expected :
          !!window.document.querySelector('[role="dialog"][aria-label="Insert block"]') && window.document.activeElement?.getAttribute("aria-label") === "Search blocks";
        if (accepted && displayed && frames >= 2) state.result = { elapsedMS: performance.now() - start, frameCount: frames };
        else if (performance.now() - start > 30_000) state.result = { elapsedMS: performance.now() - start, frameCount: frames, error: "Accepted content and rendered/focused surface did not settle" };
        else requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    }
    source.addEventListener(type, begin, true); window.modernMeasurement = state;
  }, { mode, expected });
}
async function result(page: Page) {
  await expect.poll(() => page.evaluate(() => !!window.modernMeasurement?.result), { timeout: 45_000 }).toBe(true);
  const value = await page.evaluate(() => window.modernMeasurement!.result!); expect(value.error).toBeUndefined(); return value.elapsedMS;
}

test("production modern surface measures original input and menu response on 1000 mixed blocks", async ({ page, browser }, info) => {
  const fixture = readFileSync("benchmarks/modern-surface-1000.json"), document = JSON.parse(fixture.toString()) as ModernDocument;
  const wasm = readFileSync(process.env.BLOCK_EDITOR_WASM ?? "dist/block-editor.wasm");
  const output = process.env.MODERN_PERFORMANCE_OUTPUT ?? ".build/finishing/20261014/modern-performance";
  mkdirSync(output, { recursive: true });
  const report: Record<string, unknown> = { complete: false, sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
    sourceClean: !execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim(), fixtureSHA256: createHash("sha256").update(fixture).digest("hex"),
    wasmSHA256: createHash("sha256").update(wasm).digest("hex"), browser: info.project.name, browserVersion: browser.version(),
    warmups: 3, repetitions: 20, inputMS: [], menuMS: [], productionReact: true,
    method: "Trusted native beforeinput/pointerdown to the second animation frame with accepted text and rendered content/menu focus verified; conservative presented-frame proxy, includes at least one frame opportunity. Sequential warmups excluded. No network/disk-cold startup or physical input/assistive acceptance claim." };
  const publish = () => writeFileSync(resolve(output, `${info.project.name}.json`), JSON.stringify(report, null, 2) + "\n");
  try {
    await page.route("**/modern-engine.wasm", route => route.fulfill({ body: wasm, contentType: "application/wasm" }));
    await page.goto("modern-performance.html");
    await page.evaluate(async encoded => { await window.mountModernPerformance(JSON.parse(encoded)); }, fixture.toString());
    await expect(page.getByRole("textbox", { name: "Document title", exact: true })).toBeVisible({ timeout: 120_000 });
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(document);
    const body = page.locator('[data-block-type="paragraph"]').filter({ hasText: "Note 0001." }).getByRole("textbox", { name: "Block text", exact: true });
    await body.evaluate(element => { element.setAttribute("data-measurement-input", ""); element.focus(); const range = window.document.createRange(); range.selectNodeContents(element); range.collapse(false); const selection = window.document.getSelection()!; selection.removeAllRanges(); selection.addRange(range); });
    let expected = (document.blocks.find(block => block.id === "note-1")!.content as { text: string }[]).map(node => node.text).join("");
    const input: number[] = [], menu: number[] = [];
    for (let i = 0; i < 23; i++) {
      expected += "!"; await arm(page, "input", expected); await page.keyboard.press("!"); const elapsed = await result(page);
      if (i >= 3) input.push(elapsed); report.inputMS = input; publish();
    }
    const saved = await page.evaluate(() => window.modernPerformance.session.save());
    for (let i = 0; i < 23; i++) {
      await arm(page, "menu", ""); await page.getByRole("button", { name: "Insert", exact: true }).click(); const elapsed = await result(page);
      if (i >= 3) menu.push(elapsed); report.menuMS = menu; publish();
      await page.getByRole("textbox", { name: "Search blocks" }).press("Escape");
      await expect(body).toBeFocused();
    }
    expect(await page.evaluate(() => window.modernPerformance.session.save())).toEqual(saved);
    const expectedDocument = structuredClone(document); (expectedDocument.blocks.find(block => block.id === "note-1")!.content as { text: string }[])[0].text = expected;
    expect(await page.evaluate(() => window.modernPerformance.session.getSnapshot().document)).toEqual(expectedDocument);
    report.environment = await page.evaluate(() => ({ userAgent: navigator.userAgent, hardwareConcurrency: navigator.hardwareConcurrency, viewport: { width: innerWidth, height: innerHeight }, devicePixelRatio }));
    report.summary = { inputP95MS: percentile(input, .95), menuP95MS: percentile(menu, .95), targets: { inputP95MS: 50, menuP95MS: 100 } };
    report.complete = true;
    await page.screenshot({ path: info.outputPath("mixed-surface.png") });
  } catch (error) { report.error = String(error); throw error; }
  finally { publish(); await info.attach("modern-surface-performance", { path: resolve(output, `${info.project.name}.json`), contentType: "application/json" }); await page.evaluate(() => window.modernPerformance?.dispose()); }
});
