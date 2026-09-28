import { expect, test } from "@playwright/test";
test.beforeEach(async ({ page }) => {
  await page.goto("authoring-test.html");
});
test("filters slash commands, shortcuts and image insertion without changing defaults", async ({
  page,
}) => {
  const input = page.locator("[contenteditable=true]").first();
  await input.fill("/");
  await expect(
    page.getByRole("option").filter({ hasText: "Table" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("option").filter({ hasText: "Callout" }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Add image", exact: true }),
  ).toHaveCount(0);
  await input.fill("/table");
  await expect(page.getByRole("option")).toHaveCount(0);
  await input.fill("");
  await input.pressSequentially("[ ] ");
  await expect(page.getByTestId("document")).toContainText(
    '"type":"paragraph"',
  );
  await expect(input).toHaveText("[ ] ");
  await input.fill("/heading");
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("document")).toContainText('"type":"heading"');
  await page.getByRole("button", { name: "Toggle restrictions" }).click();
  await expect(
    page.getByRole("button", { name: "Add image", exact: true }),
  ).toBeVisible();
  await input.fill("/table");
  await expect(
    page.getByRole("option").filter({ hasText: "Table" }),
  ).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page.getByTestId("document")).toContainText('"type":"table"');
});
test("preserves existing unsupported content and uses a paragraph for Enter", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Load existing task" }).click();
  const input = page.locator("[contenteditable=true]").first();
  await expect(input).toHaveText("Saved task");
  await expect(page.getByTestId("document")).toContainText('"style":"todo"');
  await input.click();
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");
  const blocks = JSON.parse(await page.getByTestId("document").innerText());
  expect(blocks.map((b: any) => b.type)).toEqual(["list", "paragraph"]);
});
test("reduces unsupported Markdown blocks to text", async ({ page }) => {
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await page
    .getByRole("textbox", { name: "Markdown source" })
    .fill("- [ ] Keep task text\n\n# Heading");
  await page.getByRole("button", { name: "Done", exact: true }).click();
  const blocks = JSON.parse(await page.getByTestId("document").innerText());
  expect(blocks[0]).toMatchObject({
    type: "paragraph",
    content: [{ type: "text", text: "Keep task text", marks: [] }],
  });
  expect(blocks[1].type).toBe("heading");
});

test("filters conversion controls and reduces restricted rich paste to text", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Block options" }).click();
  await expect(
    page.getByRole("menuitem", { name: "Callout", exact: true }),
  ).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Paragraphs only" }).click();
  const input = page.locator("[contenteditable=true]").first();
  await input.click();
  await input.evaluate((element) => {
    const data = new DataTransfer();
    data.setData("text/html", "<h2>Heading</h2><blockquote>Quote</blockquote>");
    data.setData("text/plain", "Heading\nQuote");
    element.dispatchEvent(
      new ClipboardEvent("paste", {
        clipboardData: data,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  const blocks = JSON.parse(await page.getByTestId("document").innerText());
  expect(blocks.map((block: any) => block.type)).toEqual([
    "paragraph",
    "paragraph",
  ]);
  expect(blocks.map((block: any) => block.content[0].text)).toEqual([
    "Heading",
    "Quote",
  ]);
});
