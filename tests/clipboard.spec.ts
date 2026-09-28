import { expect, test, type Page } from "@playwright/test";

const moduleUrl = `/block-editor/@fs/${process.cwd()}/src/index.ts`;

async function parse(page: Page, html: string) {
  return page.evaluate(
    async ({ moduleUrl, html }) => {
      const { parseClipboardHtml, Content } = await import(moduleUrl);
      const blocks = parseClipboardHtml(html);
      // Validate output against the public schema as well as expected content.
      return Content.parse(blocks);
    },
    { moduleUrl, html },
  );
}

test.beforeEach(async ({ page }) => {
  await page.goto("./");
});

test("imports basic blocks and marks, flattens nested lists and unsupported tables", async ({
  page,
}) => {
  const blocks = await parse(
    page,
    "<h2>Title</h2><p>Hello <strong>bold <em>both</em></strong> <code>code</code><br>next</p><ul><li>Parent<ul><li>Child</li></ul>end</li></ul><ol><li>Numbered</li></ol><blockquote><p>Quote</p></blockquote><pre><code>a\n  b</code></pre><hr><table><tr><td>A</td><td>B</td></tr></table>",
  );
  expect(blocks.map((b: any) => b.type)).toEqual([
    "heading",
    "paragraph",
    "list",
    "list",
    "list",
    "list",
    "quote",
    "code",
    "divider",
    "paragraph",
  ]);
  expect(blocks[0]).toMatchObject({ level: 2 });
  expect(blocks[1].content).toContainEqual({
    type: "text",
    text: "both",
    marks: [{ type: "bold" }, { type: "italic" }],
  });
  expect(blocks[5]).toMatchObject({ style: "ordered" });
  expect(blocks[6].content[0].text).toBe("Quote");
  expect(blocks[7].code).toBe("a\n  b");
  expect(blocks[9].content[0].text).toBe("A\tB\t");
  expect(new Set(blocks.map((b: any) => b.id)).size).toBe(blocks.length);
});

test("drops executable content, attributes and remote images without fetching them", async ({
  page,
}) => {
  const requests: string[] = [];
  page.on("request", (request) => {
    if (request.url().includes("paste.invalid")) requests.push(request.url());
  });
  const blocks = await parse(
    page,
    '<script>alert(1)</script><style>evil</style><iframe src="https://paste.invalid/frame"></iframe><svg><text>hidden</text></svg><p onclick="alert(1)"><span style="color:red">Plain</span> <a href="javascript:alert(1)">bad</a> <a href="data:text/html,evil">data</a> <a href="/relative">relative</a> <a href="https://example.com/help">safe</a> <a href="mailto:help@example.com">mail</a><img src="https://paste.invalid/image" onerror="alert(1)" alt="Image description"></p>',
  );
  const serialized = JSON.stringify(blocks);
  expect(serialized).not.toMatch(
    /javascript:|data:text|paste.invalid|onclick|onerror|style|hidden|evil/,
  );
  expect(
    blocks[0].content.filter((n: any) =>
      n.marks.some((m: any) => m.type === "link"),
    ),
  ).toEqual([
    {
      type: "text",
      text: "safe",
      marks: [{ type: "link", href: "https://example.com/help" }],
    },
    {
      type: "text",
      text: "mail",
      marks: [{ type: "link", href: "mailto:help@example.com" }],
    },
  ]);
  expect(serialized).toContain("Image description");
  expect(requests).toEqual([]);
});

test("selection replacement preserves existing marks and structured references", async ({
  page,
}) => {
  const result = await page.evaluate(async (moduleUrl) => {
    const { pasteBlocks, parseClipboardHtml } = await import(moduleUrl);
    const block = {
      id: "original",
      type: "paragraph",
      content: [
        { type: "text", text: "😀 keep replace", marks: [{ type: "bold" }] },
        {
          type: "mention",
          entityType: "user",
          entityId: "person",
          label: "Luca",
        },
      ],
    };
    return pasteBlocks(block, parseClipboardHtml("<em>new</em>"), 8, 15);
  }, moduleUrl);
  expect(result).toMatchObject({ focusId: "original", caret: 11 });
  expect(result.blocks[0].content).toEqual([
    { type: "text", text: "😀 keep ", marks: [{ type: "bold" }] },
    { type: "text", text: "new", marks: [{ type: "italic" }] },
    { type: "mention", entityType: "user", entityId: "person", label: "Luca" },
  ]);
});

async function paste(
  page: Page,
  html: string,
  text: string,
  start: number,
  end: number,
) {
  await page
    .locator("textarea.s2be-input")
    .first()
    .evaluate(
      (node: HTMLTextAreaElement, args) => {
        node.focus();
        node.setSelectionRange(args.start, args.end);
        const clipboardData = new DataTransfer();
        clipboardData.setData("text/html", args.html);
        clipboardData.setData("text/plain", args.text);
        node.dispatchEvent(
          new ClipboardEvent("paste", {
            bubbles: true,
            cancelable: true,
            clipboardData,
          }),
        );
      },
      { html, text, start, end },
    );
}

test("React paste creates one operation, keeps surrounding text and restores the caret", async ({
  page,
}) => {
  const input = page.locator("textarea.s2be-input").first();
  await input.fill("before OLD after");
  await paste(
    page,
    "<p><b>first</b></p><p><i>second</i></p>",
    "first\nsecond",
    7,
    10,
  );
  await expect(input).toHaveValue("before first");
  const second = page.locator("textarea.s2be-input").nth(1);
  await expect(second).toHaveValue("second after");
  await expect(second).toBeFocused();
  expect(
    await second.evaluate((node: HTMLTextAreaElement) => node.selectionStart),
  ).toBe(6);
  const operation = JSON.parse(
    await page.locator(".operation-list pre").first().innerText(),
  );
  expect(operation.type).toBe("paste");
  expect(operation.blocks[0].content.at(-1).marks).toEqual([{ type: "bold" }]);
  expect(operation.blocks[1].content[0].marks).toEqual([{ type: "italic" }]);
  await second.press("!");
  await expect(second).toHaveValue("second! after");
  const afterTyping = JSON.parse(
    await page.locator(".operation-list pre").first().innerText(),
  );
  expect(afterTyping.block.content[0].marks).toEqual([{ type: "italic" }]);
});

test("literal destinations and empty or oversized imports retain native paste", async ({
  page,
}) => {
  const result = await page.evaluate(async (moduleUrl) => {
    const { parseClipboardHtml, pasteBlocks, makeBlock } = await import(
      moduleUrl
    );
    const imported = parseClipboardHtml("<b>bold</b>");
    return [
      pasteBlocks(makeBlock("code", "literal"), imported, 0, 0),
      pasteBlocks(makeBlock("paragraph"), [], 0, 0),
      parseClipboardHtml("x".repeat(1_000_001)),
      parseClipboardHtml("<p>x</p>".repeat(5001)),
      parseClipboardHtml("<span>".repeat(150) + "deep" + "</span>".repeat(150)),
      parseClipboardHtml("<pre>" + "x".repeat(100_001) + "</pre>"),
    ];
  }, moduleUrl);
  expect(result).toEqual([null, null, [], [], [], []]);
});
