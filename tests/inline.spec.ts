import { expect, test, type Locator } from "@playwright/test";

async function select(editor: Locator, start: number, end = start) {
  await editor.evaluate(
    (root, { start, end }) => {
      root.focus();
      const texts: Text[] = [];
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode())
        texts.push(node as Text);
      const point = (offset: number): [Node, number] => {
        for (const node of texts) {
          if (offset <= node.length) return [node, offset];
          offset -= node.length;
        }
        return [root, 0];
      };
      const range = document.createRange();
      range.setStart(...point(start));
      range.setEnd(...point(end));
      document.getSelection()!.removeAllRanges();
      document.getSelection()!.addRange(range);
    },
    { start, end },
  );
}

async function paste(editor: Locator, html: string, text = "") {
  await editor.evaluate(
    (root, { html, text }) => {
      const clipboardData = new DataTransfer();
      clipboardData.setData("text/html", html);
      clipboardData.setData("text/plain", text);
      root.dispatchEvent(
        new ClipboardEvent("paste", {
          bubbles: true,
          cancelable: true,
          clipboardData,
        }),
      );
    },
    { html, text },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("./");
});

test("formats selected text visibly and supports undo/redo and continued typing", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("alpha beta");
  await select(editor, 0, 5);
  await page.getByRole("button", { name: "Bold", exact: true }).click();
  await expect(editor.locator("strong")).toHaveText("alpha");
  await editor.press("ControlOrMeta+i");
  await expect(editor.locator("em strong")).toHaveText("alpha");
  await editor.press("ControlOrMeta+z");
  await expect(editor.locator("em")).toHaveCount(0);
  await expect(editor.locator("strong")).toHaveText("alpha");
  await editor.press("ControlOrMeta+Shift+z");
  await expect(editor.locator("em strong")).toHaveText("alpha");
  await select(editor, 10);
  await page.getByRole("button", { name: "Bold", exact: true }).click();
  await editor.pressSequentially("!");
  await expect(editor).toHaveText("alpha beta!");
  await expect(editor.locator("strong").last()).toHaveText("!");
});

test("uses the actual edit range for repeated text and preserves adjacent marks", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("");
  await select(editor, 0);
  await paste(editor, "<strong>a</strong>a");
  await select(editor, 1);
  await editor.press("Backspace");
  await expect(editor).toHaveText("a");
  await expect(editor.locator("strong")).toHaveCount(0);
  await editor.press("ControlOrMeta+z");
  await expect(editor).toHaveText("aa");
  await expect(editor.locator("strong")).toHaveText("a");
  await select(editor, 0, 1);
  await editor.pressSequentially("b");
  await expect(editor).toHaveText("ba");
  await expect(editor.locator("strong")).toHaveText("b");
});

test("splits structured content at Enter and retains line breaks with Shift+Enter", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("");
  await select(editor, 0);
  await paste(editor, "<b>alpha beta</b>");
  await select(editor, 6);
  await editor.press("Enter");
  await expect(editor).toHaveText("alpha ");
  const next = page.locator(".s2be-rich-input").nth(1);
  await expect(next.locator("strong")).toHaveText("beta");
  await expect(next).toBeFocused();
  await next.pressSequentially("new ");
  await expect(next).toHaveText("new beta");
  await next.press("Shift+Enter");
  expect(await next.textContent()).toBe("new \nbeta");
  await next.press("ControlOrMeta+z");
  await expect(next).toHaveText("new beta");
});

test("applies and removes links inline, rejects unsafe URLs and renders pasted code", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("Documentation");
  await select(editor, 0, 13);
  await page.getByRole("button", { name: "Link", exact: true }).click();
  await page
    .getByRole("textbox", { name: "Link address" })
    .fill("javascript:alert(1)");
  await page.getByRole("button", { name: "Apply link", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Use an absolute http, https or mailto address.",
  );
  await page
    .getByRole("textbox", { name: "Link address" })
    .fill("https://example.com/help");
  await page.getByRole("button", { name: "Apply link", exact: true }).click();
  await expect(editor.locator("a")).toHaveAttribute(
    "href",
    "https://example.com/help",
  );
  await editor.locator("a").click();
  await expect(page).toHaveURL(/block-editor\/$/);
  await select(editor, 0, 13);
  await page.getByRole("button", { name: "Link", exact: true }).click();
  await page.getByRole("button", { name: "Remove link", exact: true }).click();
  await expect(editor.locator("a")).toHaveCount(0);
  await select(editor, 0, 13);
  await paste(editor, "<code>const value = 1</code>");
  await expect(editor.locator("code")).toHaveText("const value = 1");
});

test("preserves composition text and accepts plain-text paste without HTML insertion", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("");
  await select(editor, 0);
  await page.getByRole("button", { name: "Bold", exact: true }).click();
  await editor.evaluate((root) => {
    root.dispatchEvent(
      new CompositionEvent("compositionstart", { bubbles: true }),
    );
    root.textContent = "日本語";
    root.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        data: "日本語",
        isComposing: true,
        inputType: "insertCompositionText",
      }),
    );
    root.dispatchEvent(
      new CompositionEvent("compositionend", { bubbles: true, data: "日本語" }),
    );
  });
  await expect(editor.locator("strong")).toHaveText("日本語");
  await select(editor, 3);
  await paste(editor, "", "<img src=x>\nplain");
  expect(await editor.textContent()).toBe("日本語<img src=x>\nplain");
  await expect(editor.locator("img")).toHaveCount(0);
});

test("formatting is usable at a mobile viewport", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("Mobile formatting");
  await select(editor, 0, 6);
  await page.getByRole("button", { name: "Italic", exact: true }).click();
  await expect(editor.locator("em")).toHaveText("Mobile");
  const toolbar = page.getByRole("toolbar", { name: "Text formatting" });
  const box = await toolbar.boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(0);
  expect(box!.x + box!.width).toBeLessThanOrEqual(390);
  await page.screenshot({
    path: testInfo.outputPath("inline-mobile.png"),
    fullPage: false,
  });
});

test("handles mobile paragraph, line-break and undo input events", async ({
  page,
}) => {
  const editor = page.locator(".s2be-rich-input").first();
  await editor.fill("first second");
  await select(editor, 6);
  await editor.evaluate((root) =>
    root.dispatchEvent(
      new InputEvent("beforeinput", {
        bubbles: true,
        cancelable: true,
        inputType: "insertParagraph",
      }),
    ),
  );
  await expect(editor).toHaveText("first ");
  const next = page.locator(".s2be-rich-input").nth(1);
  await expect(next).toHaveText("second");
  await select(next, 0);
  await next.evaluate((root) =>
    root.dispatchEvent(
      new InputEvent("beforeinput", {
        bubbles: true,
        cancelable: true,
        inputType: "insertLineBreak",
      }),
    ),
  );
  expect(await next.textContent()).toBe("\nsecond");
  await next.evaluate((root) =>
    root.dispatchEvent(
      new InputEvent("beforeinput", {
        bubbles: true,
        cancelable: true,
        inputType: "historyUndo",
      }),
    ),
  );
  await expect(next).toHaveText("second");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(editor).toHaveText("first second");
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect(editor).toHaveText("first ");
  await expect(page.locator(".s2be-rich-input").nth(1)).toHaveText("second");
});
