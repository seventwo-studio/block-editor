import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.goto("/");
  await page.evaluate(async source => {
    (window as any).loadingFixture = await import(/* @vite-ignore */ source);
  }, `/block-editor/@fs${process.cwd()}/tests/swift-loading-harness.ts`);
});

async function mount(page: import("@playwright/test").Page, options: Record<string, unknown> = {}) {
  await page.evaluate(options => { (window as any).loading = (window as any).loadingFixture.mount(options); }, options);
}

for (const load of ["throwOnce", "rejectOnce"]) {
  test(`${load} exposes failure details and opens a fresh session on Retry`, async ({ page }) => {
    const errors: string[] = []; page.on("pageerror", error => errors.push(error.message));
    await mount(page, { load });
    await expect(page.locator("#loading-harness").getByRole("alert")).toContainText(load === "throwOnce" ? "synchronous load failed" : "network unavailable");
    await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toHaveCount(0);
    await page.locator("#loading-harness").getByRole("button", { name: "Retry" }).click();
    await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
    expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "load", "initialize", "create:first", "ready:first"]);
    expect(errors).toEqual([]);
  });
}

test("loading remains visible until the module resolves", async ({ page }) => {
  await mount(page, { load: "deferred" });
  await expect(page.locator("#loading-harness").getByRole("status")).toHaveText("Loading editor…");
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toHaveCount(0);
  await page.evaluate(() => (window as any).loading.resolve());
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
});

test("a replaced document cannot initialize or publish the previous pending load", async ({ page }) => {
  await mount(page, { load: "deferred" });
  await expect.poll(() => page.evaluate(() => (window as any).loading.events.length)).toBe(1);
  await page.evaluate(() => (window as any).loading.replace("second"));
  await expect.poll(() => page.evaluate(() => (window as any).loading.events.length)).toBe(2);
  await page.evaluate(() => { (window as any).loading.resolve(0); (window as any).loading.resolve(1); });
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
  expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "load", "initialize", "create:second", "ready:second"]);
});

test("an old loader rejection cannot replace the new document with an error", async ({ page }) => {
  await mount(page, { load: "deferred" });
  await expect(page.locator("#loading-harness").getByRole("status")).toBeVisible();
  await page.evaluate(() => (window as any).loading.replace("second"));
  await expect.poll(() => page.evaluate(() => (window as any).loading.events.length)).toBe(2);
  await page.evaluate(() => { (window as any).loading.reject(0); (window as any).loading.resolve(1); });
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
  await expect(page.locator("#loading-harness").getByRole("alert")).toHaveCount(0);
});

test("unmount cancels a pending load before runtime initialization", async ({ page }) => {
  await mount(page, { load: "deferred" });
  await expect(page.locator("#loading-harness").getByRole("status")).toBeVisible();
  await page.evaluate(async () => {
    const h = (window as any).loading; h.unmount(); h.resolve();
    await new Promise(resolve => setTimeout(resolve, 0));
  });
  expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load"]);
});

test("unmount during initialization cannot create a session", async ({ page }) => {
  await mount(page, { deferInitialize: true });
  await expect.poll(() => page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize"]);
  await page.evaluate(async () => {
    const h = (window as any).loading; h.unmount(); h.finishInitialize();
    await new Promise(resolve => setTimeout(resolve, 0));
  });
  expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize"]);
});

test("a host that unmounts onReady still disconnects and closes the session", async ({ page }) => {
  await mount(page, { unmountOnReady: true });
  await expect.poll(() => page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize", "create:first", "ready:first", "close:first", "disconnect:first"]);
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toHaveCount(0);
});

for (const fail of ["create", "restore", "ready"]) {
  test(`${fail} failure preserves details and disposes any created session before Retry`, async ({ page }) => {
    await mount(page, { fail });
    await expect(page.locator("#loading-harness").getByRole("alert")).toContainText(fail === "restore" ? "incompatible snapshot version" : fail === "ready" ? "host connection failed" : "create failed");
    const failed = await page.evaluate(() => (window as any).loading.events);
    expect(failed.filter((e: string) => e === "close:first")).toHaveLength(fail === "ready" ? 1 : 0);
    await page.evaluate(() => (window as any).loading.clearFailure());
    await page.locator("#loading-harness").getByRole("button", { name: "Retry" }).click();
    await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
    await page.evaluate(() => (window as any).loading.unmount());
    expect((await page.evaluate(() => (window as any).loading.events)).filter((e: string) => e === "close:first")).toHaveLength(fail === "ready" ? 2 : 1);
  });
}

test("a failing host disconnect still closes the session and permits replacement", async ({ page }) => {
  const errors: string[] = []; page.on("pageerror", error => errors.push(error.message));
  await mount(page, { fail: "disconnect" });
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
  await page.evaluate(() => (window as any).loading.replace("second"));
  await expect.poll(() => page.evaluate(() => (window as any).loading.events.includes("ready:second"))).toBe(true);
  expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize", "create:first", "ready:first", "disconnect:first", "close:first", "load", "initialize", "create:second", "ready:second"]);
  expect(errors).toEqual([]);
});

for (const load of ["invalidBytes", "missingExports"]) {
  test(`${load} fails through the actual WASM initializer without opening an editor`, async ({ page }) => {
    await mount(page, { load });
    await expect(page.locator("#loading-harness").getByRole("alert")).toContainText(load === "missingExports" ? "Missing Swift WASM export" : "CompileError");
    expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize"]);
    await expect(page.locator("#loading-harness").getByRole("button", { name: "Retry" })).toBeVisible();
  });
}

test("StrictMode leaves one live session and closes it exactly once", async ({ page }) => {
  await mount(page, { strict: true });
  await expect(page.locator("#loading-harness").getByRole("button", { name: "Add paragraph" })).toBeVisible();
  await page.evaluate(() => (window as any).loading.unmount());
  expect(await page.evaluate(() => (window as any).loading.events)).toEqual(["load", "initialize", "create:first", "ready:first", "disconnect:first", "close:first"]);
});
