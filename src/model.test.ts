import { describe, expect, it } from "bun:test"
import {
  blockClasses,
  filterSlashCommands,
  getBlockText,
  getConvertibleTypes,
  getEnterBehavior,
  getListPrefix,
  getPlaceholder,
  getSlashQuery,
  insertAfter,
  isBlockEmpty,
  makeBlock,
  parseMarkdownToBlocks,
  plainText,
  removeFromArray,
  replaceBlockInArray,
  SLASH_COMMANDS,
  serializeBlocksToMarkdown,
  setBlockText,
  toSimpleType,
  transformShortcut,
} from "./model"

describe("plainText", () => {
  it("extracts text from text nodes", () => {
    expect(plainText([{ type: "text", text: "hello", marks: [] }])).toBe(
      "hello",
    )
  })

  it("extracts text from mixed inline nodes", () => {
    expect(
      plainText([
        { type: "text", text: "hi ", marks: [] },
        {
          type: "mention",
          entityType: "user",
          entityId: "u1",
          label: "Alice",
        },
      ]),
    ).toBe("hi Alice")
  })

  it("returns empty string for empty array", () => {
    expect(plainText([])).toBe("")
  })
})

describe("getBlockText / setBlockText", () => {
  it("gets and sets paragraph text", () => {
    const block = makeBlock("paragraph", "Hello")
    expect(getBlockText(block)).toBe("Hello")
    const updated = setBlockText(block, "World")
    expect(getBlockText(updated)).toBe("World")
  })

  it("gets and sets heading text", () => {
    const block = makeBlock("heading1", "Title")
    expect(getBlockText(block)).toBe("Title")
    const updated = setBlockText(block, "New Title")
    expect(getBlockText(updated)).toBe("New Title")
  })

  it("gets and sets code block text", () => {
    const block = makeBlock("code", "const x = 1")
    expect(getBlockText(block)).toBe("const x = 1")
    const updated = setBlockText(block, "let y = 2")
    expect(getBlockText(updated)).toBe("let y = 2")
  })

  it("gets divider text as empty string", () => {
    expect(getBlockText(makeBlock("divider"))).toBe("")
  })
})

describe("makeBlock", () => {
  it("creates paragraph with content", () => {
    const block = makeBlock("paragraph", "Hello")
    expect(block.type).toBe("paragraph")
    if (block.type === "paragraph") {
      expect(plainText(block.content)).toBe("Hello")
    }
  })

  it("creates heading with correct level", () => {
    const h1 = makeBlock("heading1", "Title")
    expect(h1.type).toBe("heading")
    if (h1.type === "heading") expect(h1.level).toBe(1)

    const h2 = makeBlock("heading2", "Sub")
    if (h2.type === "heading") expect(h2.level).toBe(2)

    const h3 = makeBlock("heading3", "Minor")
    if (h3.type === "heading") expect(h3.level).toBe(3)
  })

  it("creates unordered list", () => {
    const block = makeBlock("bullet", "Item")
    expect(block.type).toBe("list")
    if (block.type === "list") {
      expect(block.style).toBe("unordered")
      expect(block.items).toHaveLength(1)
    }
  })

  it("creates ordered list", () => {
    const block = makeBlock("ordered", "Item")
    expect(block.type).toBe("list")
    if (block.type === "list") expect(block.style).toBe("ordered")
  })

  it("creates todo list", () => {
    const block = makeBlock("todo", "Task")
    expect(block.type).toBe("list")
    if (block.type === "list") {
      expect(block.style).toBe("todo")
      expect(block.items[0]?.checked).toBe(false)
    }
  })

  it("creates code block", () => {
    const block = makeBlock("code", "x = 1")
    expect(block.type).toBe("code")
    if (block.type === "code") expect(block.code).toBe("x = 1")
  })

  it("creates divider", () => {
    expect(makeBlock("divider").type).toBe("divider")
  })

  it("creates table with header + body row", () => {
    const block = makeBlock("table")
    expect(block.type).toBe("table")
    if (block.type === "table") {
      expect(block.rows).toHaveLength(2)
      expect(block.rows[0].cells).toHaveLength(3)
    }
  })

  it("generates unique ids", () => {
    const a = makeBlock("paragraph")
    const b = makeBlock("paragraph")
    expect(a.id).not.toBe(b.id)
  })
})

describe("transformShortcut", () => {
  it("transforms # to heading1", () => {
    const para = makeBlock("paragraph")
    const result = transformShortcut("# ", para)
    expect(result?.block?.type).toBe("heading")
  })

  it("transforms ## to heading2", () => {
    const result = transformShortcut("## ", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("heading")
  })

  it("transforms - to bullet list", () => {
    const result = transformShortcut("- ", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("list")
  })

  it("transforms 1. to ordered list", () => {
    const result = transformShortcut("1. ", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("list")
  })

  it("transforms [] to todo list", () => {
    const result = transformShortcut("[] ", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("list")
    if (result?.block?.type === "list") {
      expect(result.block.style).toBe("todo")
    }
  })

  it("transforms > to quote", () => {
    const result = transformShortcut("> ", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("quote")
  })

  it("transforms ``` to code", () => {
    const result = transformShortcut("```", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("code")
  })

  it("transforms --- to divider", () => {
    const result = transformShortcut("---", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("divider")
  })

  it("returns null when transforming a heading to the same level", () => {
    expect(transformShortcut("# ", makeBlock("heading1"))).toBeNull()
    expect(transformShortcut("## ", makeBlock("heading2"))).toBeNull()
    expect(transformShortcut("### ", makeBlock("heading3"))).toBeNull()
  })

  it("switches heading levels", () => {
    const h1 = transformShortcut("## ", makeBlock("heading1"))
    expect(h1?.block?.type).toBe("heading")
    if (h1?.block?.type === "heading") expect(h1.block.level).toBe(2)

    const h2 = transformShortcut("### ", makeBlock("heading2"))
    if (h2?.block?.type === "heading") expect(h2.block.level).toBe(3)

    const h3 = transformShortcut("# ", makeBlock("heading3"))
    if (h3?.block?.type === "heading") expect(h3.block.level).toBe(1)
  })

  it("preserves trailing content when heading prefix is typed before existing text", () => {
    const result = transformShortcut("## Hello world", makeBlock("paragraph"))
    expect(result?.block?.type).toBe("heading")
    if (result?.block?.type === "heading") {
      expect(result.block.level).toBe(2)
      expect(plainText(result.block.content)).toBe("Hello world")
    }
  })

  it("returns null for non-shortcut text", () => {
    expect(transformShortcut("hello", makeBlock("paragraph"))).toBeNull()
  })

  it("returns null for non-paragraph, non-heading blocks", () => {
    expect(transformShortcut("# ", makeBlock("bullet"))).toBeNull()
    expect(transformShortcut("# ", makeBlock("quote"))).toBeNull()
  })
})

describe("getEnterBehavior", () => {
  it("inserts paragraph after paragraph", () => {
    expect(getEnterBehavior(makeBlock("paragraph", "text"))).toEqual({
      action: "insert",
      type: "paragraph",
    })
  })

  it("continues bullet list when item has content", () => {
    expect(getEnterBehavior(makeBlock("bullet", "Item"))).toEqual({
      action: "insert",
      type: "bullet",
    })
  })

  it("exits list on empty item", () => {
    expect(getEnterBehavior(makeBlock("bullet"))).toEqual({
      action: "replace",
      type: "paragraph",
    })
  })

  it("continues ordered list", () => {
    expect(getEnterBehavior(makeBlock("ordered", "Item"))).toEqual({
      action: "insert",
      type: "ordered",
    })
  })

  it("continues todo list", () => {
    expect(getEnterBehavior(makeBlock("todo", "Task"))).toEqual({
      action: "insert",
      type: "todo",
    })
  })
})

describe("toSimpleType", () => {
  it("maps heading levels", () => {
    expect(toSimpleType(makeBlock("heading1"))).toBe("heading1")
    expect(toSimpleType(makeBlock("heading2"))).toBe("heading2")
    expect(toSimpleType(makeBlock("heading3"))).toBe("heading3")
  })

  it("maps list styles", () => {
    expect(toSimpleType(makeBlock("bullet"))).toBe("bullet")
    expect(toSimpleType(makeBlock("ordered"))).toBe("ordered")
    expect(toSimpleType(makeBlock("todo"))).toBe("todo")
  })

  it("maps basic types", () => {
    expect(toSimpleType(makeBlock("paragraph"))).toBe("paragraph")
    expect(toSimpleType(makeBlock("quote"))).toBe("quote")
    expect(toSimpleType(makeBlock("code"))).toBe("code")
    expect(toSimpleType(makeBlock("divider"))).toBe("divider")
  })
})

describe("getConvertibleTypes", () => {
  it("returns text types for text blocks", () => {
    const types = getConvertibleTypes("paragraph")
    expect(types).toContain("paragraph")
    expect(types).toContain("heading1")
    expect(types).toContain("code")
    expect(types).not.toContain("bullet")
  })

  it("returns list types for list blocks", () => {
    expect(getConvertibleTypes("bullet")).toEqual(["bullet", "ordered", "todo"])
  })

  it("returns empty for standalone blocks", () => {
    expect(getConvertibleTypes("table")).toEqual([])
    expect(getConvertibleTypes("divider")).toEqual([])
  })
})

describe("getPlaceholder", () => {
  it("returns type-specific placeholders", () => {
    expect(getPlaceholder("heading1", "fb")).toBe("Heading 1")
    expect(getPlaceholder("bullet", "fb")).toBe("List item")
    expect(getPlaceholder("code", "fb")).toBe("Code")
  })

  it("returns fallback for paragraph", () => {
    expect(getPlaceholder("paragraph", "Write...")).toBe("Write...")
  })
})

describe("blockClasses", () => {
  it("returns border class for quote", () => {
    expect(blockClasses("quote")).toContain("border-l-[3px]")
  })

  it("returns callout classes", () => {
    expect(blockClasses("callout")).toContain("rounded-lg")
  })

  it("returns empty for paragraph", () => {
    expect(blockClasses("paragraph")).toBe("")
  })
})

describe("slash commands", () => {
  it("getSlashQuery extracts query from slash text", () => {
    const block = makeBlock("paragraph", "/hea")
    expect(getSlashQuery(block)).toBe("hea")
  })

  it("getSlashQuery returns null for non-slash", () => {
    expect(getSlashQuery(makeBlock("paragraph", "hello"))).toBeNull()
    expect(getSlashQuery(null)).toBeNull()
  })

  it("filterSlashCommands filters by query", () => {
    const results = filterSlashCommands("hea")
    expect(results.map((c) => c.id)).toEqual([
      "heading1",
      "heading2",
      "heading3",
    ])
  })

  it("filterSlashCommands returns all for empty query", () => {
    expect(filterSlashCommands("").length).toBe(SLASH_COMMANDS.length)
  })

  it("filterSlashCommands returns empty for null", () => {
    expect(filterSlashCommands(null)).toEqual([])
  })
})

describe("array operations", () => {
  it("replaceBlockInArray replaces the right block", () => {
    const a = makeBlock("paragraph", "A")
    const b = makeBlock("paragraph", "B")
    const replacement = makeBlock("heading1", "New")
    const result = replaceBlockInArray([a, b], a.id, replacement)
    expect(result[0].id).toBe(a.id)
    expect(result[0].type).toBe("heading")
  })

  it("insertAfter inserts after the given block", () => {
    const a = makeBlock("paragraph", "A")
    const b = makeBlock("paragraph", "B")
    const newBlock = makeBlock("divider")
    const result = insertAfter([a, b], a.id, newBlock)
    expect(result).toHaveLength(3)
    expect(result[1].type).toBe("divider")
  })

  it("removeFromArray keeps at least one block", () => {
    const a = makeBlock("paragraph", "A")
    const result = removeFromArray([a], a.id)
    expect(result).toHaveLength(1)
    expect(result[0].type).toBe("paragraph")
  })

  it("removeFromArray removes the correct block", () => {
    const a = makeBlock("paragraph", "A")
    const b = makeBlock("paragraph", "B")
    const result = removeFromArray([a, b], a.id)
    expect(result).toHaveLength(1)
    expect(result[0].id).toBe(b.id)
  })
})

describe("getListPrefix", () => {
  it("returns bullet for unordered list", () => {
    expect(getListPrefix(makeBlock("bullet"), [], 0)).toBe("•")
  })

  it("returns 1. for ordered list", () => {
    expect(getListPrefix(makeBlock("ordered"), [], 0)).toBe("1.")
  })

  it("returns empty string for todo list", () => {
    expect(getListPrefix(makeBlock("todo"), [], 0)).toBe("")
  })

  it("returns null for non-list blocks", () => {
    expect(getListPrefix(makeBlock("paragraph"), [], 0)).toBeNull()
  })
})

describe("isBlockEmpty", () => {
  it("detects empty paragraph", () => {
    expect(isBlockEmpty(makeBlock("paragraph"))).toBe(true)
  })

  it("detects non-empty paragraph", () => {
    expect(isBlockEmpty(makeBlock("paragraph", "Hello"))).toBe(false)
  })

  it("divider is always empty", () => {
    expect(isBlockEmpty(makeBlock("divider"))).toBe(true)
  })
})

describe("serializeBlocksToMarkdown", () => {
  it("serializes paragraphs", () => {
    expect(serializeBlocksToMarkdown([makeBlock("paragraph", "Hello")])).toBe(
      "Hello",
    )
  })

  it("serializes headings", () => {
    expect(serializeBlocksToMarkdown([makeBlock("heading1", "Title")])).toBe(
      "# Title",
    )
    expect(serializeBlocksToMarkdown([makeBlock("heading2", "Sub")])).toBe(
      "## Sub",
    )
    expect(serializeBlocksToMarkdown([makeBlock("heading3", "Mini")])).toBe(
      "### Mini",
    )
  })

  it("serializes bullet list", () => {
    expect(serializeBlocksToMarkdown([makeBlock("bullet", "Item")])).toBe(
      "- Item",
    )
  })

  it("serializes ordered list", () => {
    expect(serializeBlocksToMarkdown([makeBlock("ordered", "First")])).toBe(
      "1. First",
    )
  })

  it("serializes todo list with checked state", () => {
    const block = makeBlock("todo", "Task")
    if (block.type === "list" && block.items[0]) {
      block.items[0].checked = true
    }
    expect(serializeBlocksToMarkdown([block])).toBe("- [x] Task")

    const unchecked = makeBlock("todo", "Open")
    expect(serializeBlocksToMarkdown([unchecked])).toBe("- [ ] Open")
  })

  it("serializes quote with multiple lines", () => {
    const block = makeBlock("quote", "Line 1\nLine 2")
    expect(serializeBlocksToMarkdown([block])).toBe("> Line 1\n> Line 2")
  })

  it("serializes code block with language", () => {
    const block = makeBlock("code", "x = 1")
    if (block.type === "code") block.language = "python"
    expect(serializeBlocksToMarkdown([block])).toBe("```python\nx = 1\n```")
  })

  it("serializes divider", () => {
    expect(serializeBlocksToMarkdown([makeBlock("divider")])).toBe("---")
  })

  it("separates blocks with blank line", () => {
    const result = serializeBlocksToMarkdown([
      makeBlock("heading1", "Title"),
      makeBlock("paragraph", "Body"),
    ])
    expect(result).toBe("# Title\n\nBody")
  })

  it("serializes a table", () => {
    const result = serializeBlocksToMarkdown([makeBlock("table")])
    expect(result).toContain("| Column 1 | Column 2 | Column 3 |")
    expect(result).toContain("| --- | --- | --- |")
  })

  it("serializes a callout with variant tag", () => {
    const block = makeBlock("callout", "Heads up")
    expect(serializeBlocksToMarkdown([block])).toBe("> [!info]\n> Heads up")
  })
})

describe("parseMarkdownToBlocks", () => {
  it("parses a paragraph", () => {
    const blocks = parseMarkdownToBlocks("Hello world")
    expect(blocks).toHaveLength(1)
    expect(blocks[0].type).toBe("paragraph")
    expect(getBlockText(blocks[0])).toBe("Hello world")
  })

  it("parses headings of various levels", () => {
    const blocks = parseMarkdownToBlocks("# H1\n\n## H2\n\n### H3")
    expect(blocks).toHaveLength(3)
    expect(blocks[0].type).toBe("heading")
    if (blocks[0].type === "heading") expect(blocks[0].level).toBe(1)
    if (blocks[1].type === "heading") expect(blocks[1].level).toBe(2)
    if (blocks[2].type === "heading") expect(blocks[2].level).toBe(3)
  })

  it("parses bullet list with multiple items", () => {
    const blocks = parseMarkdownToBlocks("- one\n- two\n- three")
    expect(blocks).toHaveLength(1)
    expect(blocks[0].type).toBe("list")
    if (blocks[0].type === "list") {
      expect(blocks[0].style).toBe("unordered")
      expect(blocks[0].items).toHaveLength(3)
      expect(plainText(blocks[0].items[0].content)).toBe("one")
    }
  })

  it("parses ordered list", () => {
    const blocks = parseMarkdownToBlocks("1. First\n2. Second")
    expect(blocks).toHaveLength(1)
    expect(blocks[0].type).toBe("list")
    if (blocks[0].type === "list") {
      expect(blocks[0].style).toBe("ordered")
      expect(blocks[0].items).toHaveLength(2)
    }
  })

  it("parses todo list and checked state", () => {
    const blocks = parseMarkdownToBlocks("- [x] Done\n- [ ] Open")
    expect(blocks).toHaveLength(1)
    if (blocks[0].type === "list") {
      expect(blocks[0].style).toBe("todo")
      expect(blocks[0].items[0].checked).toBe(true)
      expect(blocks[0].items[1].checked).toBe(false)
    }
  })

  it("parses fenced code block with language", () => {
    const blocks = parseMarkdownToBlocks("```ts\nconst x = 1\n```")
    expect(blocks[0].type).toBe("code")
    if (blocks[0].type === "code") {
      expect(blocks[0].language).toBe("ts")
      expect(blocks[0].code).toBe("const x = 1")
    }
  })

  it("parses divider", () => {
    const blocks = parseMarkdownToBlocks("---")
    expect(blocks[0].type).toBe("divider")
  })

  it("parses quote", () => {
    const blocks = parseMarkdownToBlocks("> A quote\n> with two lines")
    expect(blocks[0].type).toBe("quote")
    if (blocks[0].type === "quote") {
      expect(plainText(blocks[0].content)).toBe("A quote\nwith two lines")
    }
  })

  it("parses callout with variant", () => {
    const blocks = parseMarkdownToBlocks("> [!warning]\n> Be careful")
    expect(blocks[0].type).toBe("callout")
    if (blocks[0].type === "callout") {
      expect(blocks[0].variant).toBe("warning")
      expect(plainText(blocks[0].content)).toBe("Be careful")
    }
  })

  it("parses a table", () => {
    const md = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    const blocks = parseMarkdownToBlocks(md)
    expect(blocks[0].type).toBe("table")
    if (blocks[0].type === "table") {
      expect(blocks[0].rows).toHaveLength(2)
      expect(blocks[0].rows[0].cells).toHaveLength(2)
      expect(plainText(blocks[0].rows[0].cells[0].content)).toBe("A")
      expect(plainText(blocks[0].rows[1].cells[1].content)).toBe("2")
    }
  })

  it("returns a single empty paragraph for empty input", () => {
    const blocks = parseMarkdownToBlocks("")
    expect(blocks).toHaveLength(1)
    expect(blocks[0].type).toBe("paragraph")
  })

  it("ignores leading and trailing blank lines", () => {
    const blocks = parseMarkdownToBlocks("\n\n# Title\n\n")
    expect(blocks).toHaveLength(1)
    expect(blocks[0].type).toBe("heading")
  })
})

describe("markdown round-trip", () => {
  function roundTrip(md: string): string {
    return serializeBlocksToMarkdown(parseMarkdownToBlocks(md))
  }

  it("preserves paragraphs", () => {
    expect(roundTrip("Hello world")).toBe("Hello world")
  })

  it("preserves a mixed document", () => {
    const md = [
      "# Title",
      "",
      "Some paragraph.",
      "",
      "## Section",
      "",
      "- one",
      "- two",
      "",
      "1. first",
      "2. second",
      "",
      "- [x] done",
      "- [ ] todo",
      "",
      "> a quote",
      "",
      "```ts",
      "const x = 1",
      "```",
      "",
      "---",
    ].join("\n")
    expect(roundTrip(md)).toBe(md)
  })

  it("preserves a callout", () => {
    const md = "> [!warning]\n> Be careful"
    expect(roundTrip(md)).toBe(md)
  })
})
