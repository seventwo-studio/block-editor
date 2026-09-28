import { expect, test, type Page } from "@playwright/test";

const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
  "base64",
);
const file = { name: "test.png", mimeType: "image/png", buffer: png };
async function load(page: Page) {
  await page.route("**/test-image/**", (route) =>
    route.fulfill({ contentType: "image/png", body: png }),
  );
  await page.goto("./images-test.html");
}
async function blocks(page: Page) {
  return JSON.parse(await page.locator("#document").innerText());
}

test("uploads through the host, renders its resolved URL and preserves alt text on replacement", async ({
  page,
}) => {
  let uploads = 0;
  await page.route("**/test-upload", (route) =>
    route.fulfill({
      json: {
        src: `asset-${++uploads}`,
        width: 1,
        height: 1,
        secret: "do-not-persist",
      },
    }),
  );
  await load(page);
  await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
  const image = page.locator(".s2be-image img");
  await expect(image).toHaveAttribute("src", "/test-image/asset-1");
  await expect(image).toHaveJSProperty("naturalWidth", 1);
  await page
    .getByLabel("Image description (alt text)")
    .fill("Our app settings");
  await expect(image).toHaveAttribute("alt", "Our app settings");
  expect(JSON.stringify(await blocks(page))).not.toContain("do-not-persist");
  const originalId = (await blocks(page)).find(
    (block: any) => block.type === "image",
  ).id;
  await page.getByLabel("Replace image", { exact: true }).setInputFiles(file);
  await expect(image).toHaveAttribute("src", "/test-image/asset-2");
  await expect(image).toHaveAttribute("alt", "Our app settings");
  expect(
    (await blocks(page)).find((block: any) => block.type === "image").id,
  ).toBe(originalId);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(image).toHaveAttribute("src", "/test-image/asset-1");
  await page.getByLabel("Image description (alt text)").fill("");
  await page.getByLabel("Image description (alt text)").press("Backspace");
  await expect(image).toHaveCount(1);
});

test("rejects unsupported or oversized files before calling the host", async ({
  page,
}) => {
  let uploads = 0;
  await page.route("**/test-upload", (route) => {
    uploads++;
    return route.fulfill({ json: { src: "unexpected" } });
  });
  await load(page);
  await page.getByLabel("Add image", { exact: true }).setInputFiles({
    name: "image.svg",
    mimeType: "image/svg+xml",
    buffer: Buffer.from("<svg></svg>"),
  });
  await expect(page.getByRole("alert")).toHaveText(
    "This image type is not supported.",
  );
  await page
    .getByLabel("Add image", { exact: true })
    .setInputFiles({ ...file, buffer: Buffer.alloc(1025) });
  await expect(page.getByRole("alert")).toHaveText(
    "Choose a nonempty image no larger than 1024 bytes.",
  );
  expect(uploads).toBe(0);
  expect((await blocks(page)).map((block: any) => block.type)).toEqual([
    "paragraph",
  ]);
});

test("keeps the document unchanged after an upload error and retries the selected file", async ({
  page,
}) => {
  let attempts = 0;
  await page.route("**/test-upload", (route) =>
    ++attempts === 1
      ? route.fulfill({ status: 503, body: "unavailable" })
      : route.fulfill({ json: { src: "retried" } }),
  );
  await load(page);
  await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
  await expect(page.getByRole("alert")).toHaveText(
    "Image upload failed. Try again.",
  );
  expect((await blocks(page)).map((block: any) => block.type)).toEqual([
    "paragraph",
  ]);
  await page.getByRole("button", { name: "Retry image", exact: true }).click();
  await expect(page.locator(".s2be-image img")).toHaveAttribute(
    "src",
    "/test-image/retried",
  );
  expect(attempts).toBe(2);
});

for (const action of [
  "Cancel upload",
  "Switch document",
  "Switch identical document",
]) {
  test(`${action} aborts in-flight upload and ignores its late result`, async ({
    page,
  }) => {
    let release!: () => void, finished!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const complete = new Promise<void>((resolve) => {
      finished = resolve;
    });
    await page.route("**/test-upload", async (route) => {
      await gate;
      try {
        await route.fulfill({ json: { src: "late-result" } });
      } catch {
        /* Aborted request. */
      } finally {
        finished();
      }
    });
    await load(page);
    const requested = page.waitForRequest("**/test-upload");
    await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
    await requested;
    await expect(page.locator(".s2be").getByRole("status")).toHaveText(
      "Uploading image…",
    );
    await page.getByRole("button", { name: action, exact: true }).click();
    await expect(page.getByLabel("Aborted uploads")).toHaveText("1");
    release();
    await complete;
    await expect(page.locator(".s2be-image")).toHaveCount(0);
    expect(JSON.stringify(await blocks(page))).not.toContain("late-result");
    if (action === "Switch document")
      expect((await blocks(page))[0].id).toBe("new-document");
  });
}

test("does not fetch stored source strings without an explicit host resolver", async ({
  page,
}) => {
  const requests: string[] = [];
  page.on("request", (request) => {
    if (request.url().includes("untrusted.invalid"))
      requests.push(request.url());
  });
  await load(page);
  await page.getByLabel("Resolve previews").uncheck();
  await page.getByRole("button", { name: "Load stored image" }).click();
  await expect(page.locator(".s2be").getByRole("status")).toHaveText(
    "Image preview is unavailable.",
  );
  await expect(page.locator(".s2be-image img")).toHaveCount(0);
  expect(requests).toEqual([]);
});

test("retries a failed preview without uploading the asset again", async ({
  page,
}) => {
  let previews = 0,
    uploads = 0;
  await load(page);
  await page.route("**/test-image/**", (route) =>
    ++previews === 1
      ? route.fulfill({ status: 404 })
      : route.fulfill({ contentType: "image/png", body: png }),
  );
  await page.route("**/test-upload", (route) => {
    uploads++;
    return route.fulfill({ json: { src: "preview" } });
  });
  await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
  await expect(page.locator(".s2be").getByRole("status")).toHaveText(
    "Image could not be loaded.",
  );
  await page.getByRole("button", { name: "Retry preview" }).click();
  await expect(page.locator(".s2be-image img")).toHaveJSProperty(
    "naturalWidth",
    1,
  );
  expect(previews).toBe(2);
  expect(uploads).toBe(1);
});

test("the public demo uses local decoded previews and stores an asset ID", async ({
  page,
}) => {
  await page.goto("./");
  await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
  await expect(page.locator(".s2be-image img")).toHaveAttribute(
    "src",
    /^blob:/,
  );
  await expect(page.locator(".s2be-image img")).toHaveJSProperty(
    "naturalWidth",
    1,
  );
  const operation = JSON.parse(
    await page.locator(".operation-list pre").first().innerText(),
  );
  expect(operation.block.src).toMatch(/^demo-image:/);
  expect(operation.block.width).toBe(1);
});

test("invalid host image metadata never enters the document", async ({
  page,
}) => {
  await page.route("**/test-upload", (route) =>
    route.fulfill({ json: { src: "asset", width: -1 } }),
  );
  await load(page);
  await page.getByLabel("Add image", { exact: true }).setInputFiles(file);
  await expect(page.getByRole("alert")).toHaveText(
    "Image upload failed. Try again.",
  );
  expect((await blocks(page)).map((block: any) => block.type)).toEqual([
    "paragraph",
  ]);
});

test("image controls and previews fit a narrow screen", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("./");
  const encoded = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 640;
    canvas.height = 320;
    const context = canvas.getContext("2d")!;
    context.fillStyle = "#365c4a";
    context.fillRect(0, 0, 640, 320);
    context.fillStyle = "#f7f4ef";
    context.fillRect(48, 48, 544, 224);
    return canvas.toDataURL("image/png").split(",")[1];
  });
  await page
    .getByLabel("Add image", { exact: true })
    .setInputFiles({ ...file, buffer: Buffer.from(encoded, "base64") });
  await page
    .getByLabel("Image description (alt text)")
    .fill("A preview example");
  const image = page.locator(".s2be-image img");
  await expect(image).toHaveJSProperty("naturalWidth", 640);
  await image.scrollIntoViewIfNeeded();
  const box = await image.boundingBox();
  expect(box!.width).toBeLessThanOrEqual(390);
  expect(box!.x + box!.width).toBeLessThanOrEqual(390);
  await expect(
    page.getByRole("button", { name: "Replace image", exact: true }),
  ).toBeVisible();
  await page.screenshot({
    path: testInfo.outputPath("images-mobile.png"),
    fullPage: false,
  });
});
