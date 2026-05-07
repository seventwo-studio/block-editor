import type { Block, InlineNode } from "./schema.js"

// ---------------------------------------------------------------------------
// Helpers — create blocks with a random id
// ---------------------------------------------------------------------------

function blockId(): string {
  return crypto.randomUUID()
}

function textNode(text: string): InlineNode {
  return { type: "text", text, marks: [] }
}

function textContent(text: string): InlineNode[] {
  return text ? [textNode(text)] : []
}

/** Extract plain text from an InlineNode array. */
export function plainText(nodes: InlineNode[]): string {
  return nodes
    .map((n) => {
      if (n.type === "text") return n.text
      if (n.type === "mention") return n.label
      if (n.type === "entity-ref") return n.label
      if (n.type === "emoji") return `:${n.name}:`
      if (n.type === "inline-math") return n.expression
      if (n.type === "date") return n.date
      return ""
    })
    .join("")
}

/** Get the editable text content of a block. */
export function getBlockText(block: Block): string {
  switch (block.type) {
    case "paragraph":
    case "heading":
    case "quote":
    case "callout":
      return plainText(block.content)
    case "code":
      return block.code
    case "list":
      return block.items.map((item) => plainText(item.content)).join("\n")
    case "divider":
      return ""
    case "image":
      return block.alt
    case "table":
      return block.rows
        .map((row) =>
          row.cells.map((cell) => plainText(cell.content)).join(" | "),
        )
        .join("\n")
    case "embed":
      return block.url
    case "math":
      return block.expression
    case "toggle":
      return plainText(block.summary)
    default:
      return ""
  }
}

/** Update the text content of a block. */
export function setBlockText(block: Block, text: string): Block {
  switch (block.type) {
    case "paragraph":
    case "heading":
    case "quote":
    case "callout":
      return { ...block, content: textContent(text) }
    case "code":
      return { ...block, code: text }
    case "list":
      return {
        ...block,
        items: block.items.map((item, i) =>
          i === 0 ? { ...item, content: textContent(text) } : item,
        ),
      }
    case "math":
      return { ...block, expression: text }
    case "toggle":
      return { ...block, summary: textContent(text) }
    default:
      return block
  }
}

// ---------------------------------------------------------------------------
// Block factories
// ---------------------------------------------------------------------------

export type SimpleBlockType =
  | "paragraph"
  | "heading1"
  | "heading2"
  | "heading3"
  | "bullet"
  | "ordered"
  | "todo"
  | "quote"
  | "callout"
  | "code"
  | "divider"
  | "table"

export function makeBlock(type: SimpleBlockType, text = ""): Block {
  const id = blockId()
  switch (type) {
    case "paragraph":
      return { id, type: "paragraph", content: textContent(text) }
    case "heading1":
      return { id, type: "heading", level: 1, content: textContent(text) }
    case "heading2":
      return { id, type: "heading", level: 2, content: textContent(text) }
    case "heading3":
      return { id, type: "heading", level: 3, content: textContent(text) }
    case "bullet":
      return {
        id,
        type: "list",
        style: "unordered",
        items: [{ id: blockId(), content: textContent(text), children: [] }],
      }
    case "ordered":
      return {
        id,
        type: "list",
        style: "ordered",
        items: [{ id: blockId(), content: textContent(text), children: [] }],
      }
    case "todo":
      return {
        id,
        type: "list",
        style: "todo",
        items: [
          {
            id: blockId(),
            content: textContent(text),
            checked: false,
            children: [],
          },
        ],
      }
    case "quote":
      return { id, type: "quote", content: textContent(text) }
    case "callout":
      return {
        id,
        type: "callout",
        variant: "info",
        icon: "lightbulb",
        content: textContent(text),
      }
    case "code":
      return { id, type: "code", language: "", code: text }
    case "divider":
      return { id, type: "divider" }
    case "table":
      return {
        id,
        type: "table",
        rows: [
          {
            id: blockId(),
            cells: [
              { id: blockId(), content: textContent("Column 1"), header: true },
              { id: blockId(), content: textContent("Column 2"), header: true },
              { id: blockId(), content: textContent("Column 3"), header: true },
            ],
          },
          {
            id: blockId(),
            cells: [
              { id: blockId(), content: [], header: false },
              { id: blockId(), content: [], header: false },
              { id: blockId(), content: [], header: false },
            ],
          },
        ],
      }
  }
}

// ---------------------------------------------------------------------------
// Slash commands
// ---------------------------------------------------------------------------

export interface SlashCommand {
  id: SimpleBlockType
  title: string
  description: string
  apply: () => Block
}

export const SLASH_COMMANDS: SlashCommand[] = [
  {
    id: "paragraph",
    title: "Text",
    description: "Plain paragraph",
    apply: () => makeBlock("paragraph"),
  },
  {
    id: "heading1",
    title: "Heading 1",
    description: "Large section title",
    apply: () => makeBlock("heading1"),
  },
  {
    id: "heading2",
    title: "Heading 2",
    description: "Medium section title",
    apply: () => makeBlock("heading2"),
  },
  {
    id: "heading3",
    title: "Heading 3",
    description: "Small section title",
    apply: () => makeBlock("heading3"),
  },
  {
    id: "bullet",
    title: "Bullet List",
    description: "Unordered list",
    apply: () => makeBlock("bullet"),
  },
  {
    id: "ordered",
    title: "Numbered List",
    description: "Ordered list",
    apply: () => makeBlock("ordered"),
  },
  {
    id: "todo",
    title: "To-do List",
    description: "Checklist with checkboxes",
    apply: () => makeBlock("todo"),
  },
  {
    id: "quote",
    title: "Quote",
    description: "Indented quote block",
    apply: () => makeBlock("quote"),
  },
  {
    id: "callout",
    title: "Callout",
    description: "Highlighted callout box",
    apply: () => makeBlock("callout"),
  },
  {
    id: "code",
    title: "Code Block",
    description: "Multi-line code",
    apply: () => makeBlock("code"),
  },
  {
    id: "divider",
    title: "Divider",
    description: "Horizontal rule",
    apply: () => makeBlock("divider"),
  },
  {
    id: "table",
    title: "Table",
    description: "Rows and columns",
    apply: () => makeBlock("table"),
  },
]

// ---------------------------------------------------------------------------
// Slash command filtering
// ---------------------------------------------------------------------------

export function getSlashQuery(block: Block | null): string | null {
  if (!block) return null
  const text = getBlockText(block)
  if (!text.startsWith("/")) return null
  return text.slice(1).trim().toLowerCase()
}

export function filterSlashCommands(query: string | null): SlashCommand[] {
  if (query === null) return []
  const q = query.toLowerCase()
  return SLASH_COMMANDS.filter((cmd) => {
    const haystack = `${cmd.title} ${cmd.description} ${cmd.id}`.toLowerCase()
    return haystack.includes(q)
  })
}

// ---------------------------------------------------------------------------
// Keyboard shortcut transforms (e.g. typing "# " converts to heading)
// ---------------------------------------------------------------------------

export function transformShortcut(
  text: string,
  block: Block,
): Partial<{ block: Block }> | null {
  const headingPrefix = text.match(/^(#{1,3}) /)
  if (headingPrefix) {
    if (block.type !== "paragraph" && block.type !== "heading") return null
    const level = headingPrefix[1].length as 1 | 2 | 3
    const rest = text.slice(headingPrefix[0].length)
    if (block.type === "heading" && block.level === level && rest === "") {
      return null
    }
    const target = `heading${level}` as SimpleBlockType
    return { block: makeBlock(target, rest) }
  }

  if (block.type !== "paragraph") return null

  if (text === "- " || text === "* ") return { block: makeBlock("bullet") }
  if (text === "1. ") return { block: makeBlock("ordered") }
  if (text === "[] " || text === "[ ] ") return { block: makeBlock("todo") }
  if (text === "> ") return { block: makeBlock("quote") }
  if (text === "```") return { block: makeBlock("code") }
  if (text === "---") return { block: makeBlock("divider") }

  return null
}

// ---------------------------------------------------------------------------
// Enter behavior
// ---------------------------------------------------------------------------

export type EnterBehavior =
  | { action: "insert"; type: SimpleBlockType }
  | { action: "replace"; type: SimpleBlockType }

export function getEnterBehavior(block: Block): EnterBehavior {
  if (block.type === "list") {
    const firstItem = block.items[0]
    const hasContent = firstItem && plainText(firstItem.content).trim() !== ""
    if (hasContent) {
      const style = block.style
      const type: SimpleBlockType =
        style === "ordered" ? "ordered" : style === "todo" ? "todo" : "bullet"
      return { action: "insert", type }
    }
    return { action: "replace", type: "paragraph" }
  }
  return { action: "insert", type: "paragraph" }
}

// ---------------------------------------------------------------------------
// Block type helpers
// ---------------------------------------------------------------------------

/** Map a Block to a SimpleBlockType for UI purposes. */
export function toSimpleType(block: Block): SimpleBlockType {
  switch (block.type) {
    case "paragraph":
      return "paragraph"
    case "heading":
      return `heading${block.level}` as SimpleBlockType
    case "list":
      return block.style === "ordered"
        ? "ordered"
        : block.style === "todo"
          ? "todo"
          : "bullet"
    case "quote":
      return "quote"
    case "callout":
      return "callout"
    case "code":
      return "code"
    case "divider":
      return "divider"
    case "table":
      return "table"
    default:
      return "paragraph"
  }
}

export function getConvertibleTypes(type: SimpleBlockType): SimpleBlockType[] {
  const textTypes: SimpleBlockType[] = [
    "paragraph",
    "heading1",
    "heading2",
    "heading3",
    "quote",
    "callout",
    "code",
  ]
  const listTypes: SimpleBlockType[] = ["bullet", "ordered", "todo"]

  if (textTypes.includes(type)) return textTypes
  if (listTypes.includes(type)) return listTypes
  return []
}

export function getPlaceholder(
  type: SimpleBlockType,
  fallback: string,
): string {
  switch (type) {
    case "heading1":
      return "Heading 1"
    case "heading2":
      return "Heading 2"
    case "heading3":
      return "Heading 3"
    case "bullet":
    case "ordered":
    case "todo":
      return "List item"
    case "quote":
      return "Quote"
    case "callout":
      return "Callout"
    case "code":
      return "Code"
    case "table":
      return "Table"
    default:
      return fallback
  }
}

export function blockClasses(type: SimpleBlockType): string {
  if (type === "quote") return "border-l-[3px] border-foreground/25 pl-5 pr-1"
  if (type === "callout")
    return "rounded-lg border border-border bg-muted/30 px-3 py-2"
  // Note: code styling lives on CodeBlockView's root, not on the outer
  // block wrapper, so `overflow-hidden` doesn't clip the grip handle.
  return ""
}

// ---------------------------------------------------------------------------
// Callout colors
// ---------------------------------------------------------------------------

/**
 * Hex palette offered for callout backgrounds. Picking one tints the entire
 * callout (background + border + icon) using `${color}` with alpha suffixes.
 */
export const CALLOUT_COLORS = [
  "#6366f1",
  "#3b82f6",
  "#14b8a6",
  "#22c55e",
  "#f59e0b",
  "#f97316",
  "#ef4444",
  "#ec4899",
  "#8b5cf6",
  "#64748b",
] as const

/**
 * Class + inline-style overrides for a callout that has a custom `color`.
 * Returns the wrapper classes that replace the default neutral muted look,
 * plus an inline `style` carrying the alpha-blended background/border.
 *
 * When `color` is undefined, the default `blockClasses("callout")` is used
 * directly with no extra style.
 */
export function calloutColorStyle(color: string): {
  className: string
  style: { backgroundColor: string; borderColor: string }
} {
  return {
    className: "rounded-lg border px-3 py-2",
    style: {
      backgroundColor: `${color}1a`,
      borderColor: `${color}40`,
    },
  }
}

// ---------------------------------------------------------------------------
// Code block languages
// ---------------------------------------------------------------------------

/**
 * Languages we expose in the code block picker. The `prism` field maps to
 * a language id supported by `prism-react-renderer`'s bundled grammar set
 * — anything outside that set falls back to plain text.
 */
export interface CodeLanguage {
  id: string
  label: string
  prism: string
}

export const CODE_LANGUAGES: CodeLanguage[] = [
  { id: "text", label: "Plain text", prism: "text" },
  { id: "typescript", label: "TypeScript", prism: "typescript" },
  { id: "tsx", label: "TSX", prism: "tsx" },
  { id: "javascript", label: "JavaScript", prism: "javascript" },
  { id: "jsx", label: "JSX", prism: "jsx" },
  { id: "html", label: "HTML", prism: "markup" },
  { id: "css", label: "CSS", prism: "css" },
  { id: "json", label: "JSON", prism: "json" },
  { id: "markdown", label: "Markdown", prism: "markdown" },
  { id: "bash", label: "Bash", prism: "bash" },
  { id: "shell", label: "Shell", prism: "bash" },
  { id: "python", label: "Python", prism: "python" },
  { id: "go", label: "Go", prism: "go" },
  { id: "rust", label: "Rust", prism: "rust" },
  { id: "ruby", label: "Ruby", prism: "ruby" },
  { id: "swift", label: "Swift", prism: "swift" },
  { id: "java", label: "Java", prism: "java" },
  { id: "sql", label: "SQL", prism: "sql" },
  { id: "yaml", label: "YAML", prism: "yaml" },
  { id: "toml", label: "TOML", prism: "toml" },
]

export function getCodeLanguage(id: string | undefined): CodeLanguage {
  return CODE_LANGUAGES.find((l) => l.id === id) ?? CODE_LANGUAGES[0]
}

// ---------------------------------------------------------------------------
// Block array operations
// ---------------------------------------------------------------------------

export function replaceBlockInArray(
  blocks: Block[],
  blockId: string,
  replacement: Block,
): Block[] {
  return blocks.map((b) =>
    b.id === blockId ? { ...replacement, id: blockId } : b,
  )
}

export function insertAfter(
  blocks: Block[],
  afterId: string,
  newBlock: Block,
): Block[] {
  const idx = blocks.findIndex((b) => b.id === afterId)
  if (idx === -1) return [...blocks, newBlock]
  return [...blocks.slice(0, idx + 1), newBlock, ...blocks.slice(idx + 1)]
}

export function removeFromArray(blocks: Block[], blockId: string): Block[] {
  if (blocks.length === 1) return [makeBlock("paragraph")]
  return blocks.filter((b) => b.id !== blockId)
}

/** Get the text prefix for list items. */
export function getListPrefix(
  block: Block,
  blocks: Block[],
  index: number,
): string | null {
  if (block.type !== "list") return null
  if (block.style === "unordered") return "•"
  if (block.style === "todo") return "" // checkbox rendered separately
  if (block.style === "ordered") {
    let num = 1
    for (let i = index - 1; i >= 0; i--) {
      const prev = blocks[i]
      if (prev.type === "list" && prev.style === "ordered") num++
      else break
    }
    return `${num}.`
  }
  return null
}

/** Check if a block is "empty" (no meaningful content). */
export function isBlockEmpty(block: Block): boolean {
  return getBlockText(block).trim() === ""
}

// ---------------------------------------------------------------------------
// Markdown serialization
//
// Round-trips a Block[] document to a flat markdown string and back. Inline
// formatting marks aren't preserved — only plain text within blocks. Block
// types that have no standard markdown representation (callout, math) use
// GFM-like extensions: `> [!info] ...` for callouts and `$$...$$` for math.
// ---------------------------------------------------------------------------

function serializeTableRow(cells: string[]): string {
  return `| ${cells.map((cell) => cell.replaceAll("|", "\\|")).join(" | ")} |`
}

export function serializeBlocksToMarkdown(blocks: Block[]): string {
  const parts = blocks.map((block) => {
    switch (block.type) {
      case "paragraph":
        return plainText(block.content)
      case "heading":
        return `${"#".repeat(block.level)} ${plainText(block.content)}`
      case "list": {
        return block.items
          .map((item, idx) => {
            const text = plainText(item.content)
            if (block.style === "ordered") return `${idx + 1}. ${text}`
            if (block.style === "todo") {
              return `- [${item.checked ? "x" : " "}] ${text}`
            }
            return `- ${text}`
          })
          .join("\n")
      }
      case "code": {
        const fence = "```"
        return `${fence}${block.language ?? ""}\n${block.code}\n${fence}`
      }
      case "quote":
        return plainText(block.content)
          .split("\n")
          .map((line) => (line ? `> ${line}` : ">"))
          .join("\n")
      case "callout": {
        const body = plainText(block.content)
          .split("\n")
          .map((line) => (line ? `> ${line}` : ">"))
          .join("\n")
        return `> [!${block.variant}]\n${body}`
      }
      case "divider":
        return "---"
      case "image": {
        const alt = block.alt ?? ""
        return `![${alt}](${block.src})`
      }
      case "table": {
        const rows = block.rows.map((row) =>
          row.cells.map((cell) => plainText(cell.content)),
        )
        if (rows.length === 0) return ""
        const width = rows[0]?.length ?? 0
        const header = rows[0] ?? []
        const separator = Array.from({ length: width }, () => "---")
        const body = rows.slice(1)
        return [
          serializeTableRow(header),
          serializeTableRow(separator),
          ...body.map(serializeTableRow),
        ].join("\n")
      }
      case "embed":
        return block.url
      case "math":
        return `$$\n${block.expression}\n$$`
      case "toggle": {
        const summary = plainText(block.summary)
        const inner = serializeBlocksToMarkdown(block.children)
        return `<details>\n<summary>${summary}</summary>\n\n${inner}\n</details>`
      }
      default:
        return ""
    }
  })

  // Join with a single blank line between blocks, except keep adjacent list
  // items in the same group tight (they were already joined by \n above).
  return parts.join("\n\n").trim()
}

function splitTableRow(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split(/(?<!\\)\|/)
    .map((cell) => cell.trim().replaceAll("\\|", "|"))
}

function isTableSeparatorLine(line: string): boolean {
  const cells = splitTableRow(line)
  return cells.length > 0 && cells.every((c) => /^:?-{3,}:?$/.test(c))
}

function isTableStart(lines: string[], i: number): boolean {
  const header = (lines[i] ?? "").trim()
  const sep = (lines[i + 1] ?? "").trim()
  return (
    /^\|.*\|$/.test(header) && /^\|.*\|$/.test(sep) && isTableSeparatorLine(sep)
  )
}

function makeTableBlock(rows: string[][]): Block {
  const width = Math.max(1, ...rows.map((r) => r.length))
  return {
    id: blockId(),
    type: "table",
    rows: rows.map((row, rowIdx) => ({
      id: blockId(),
      cells: Array.from({ length: width }, (_, ci) => ({
        id: blockId(),
        content: row[ci] ? [{ type: "text", text: row[ci], marks: [] }] : [],
        header: rowIdx === 0,
      })),
    })),
  }
}

export function parseMarkdownToBlocks(markdown: string): Block[] {
  const lines = markdown.replaceAll("\r\n", "\n").split("\n")
  const blocks: Block[] = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i] ?? ""

    // Skip blank lines
    if (!line.trim()) {
      i += 1
      continue
    }

    // Fenced code block
    const fenceMatch = line.match(/^```(\S*)\s*$/)
    if (fenceMatch) {
      const language = fenceMatch[1] ?? ""
      const codeLines: string[] = []
      i += 1
      while (i < lines.length && !/^```\s*$/.test(lines[i] ?? "")) {
        codeLines.push(lines[i] ?? "")
        i += 1
      }
      if (i < lines.length) i += 1
      blocks.push({
        id: blockId(),
        type: "code",
        language,
        code: codeLines.join("\n"),
      })
      continue
    }

    // Math block
    if (line.trim() === "$$") {
      const exprLines: string[] = []
      i += 1
      while (i < lines.length && (lines[i] ?? "").trim() !== "$$") {
        exprLines.push(lines[i] ?? "")
        i += 1
      }
      if (i < lines.length) i += 1
      blocks.push({
        id: blockId(),
        type: "math",
        expression: exprLines.join("\n"),
      })
      continue
    }

    // Divider
    if (/^---+$/.test(line.trim())) {
      blocks.push({ id: blockId(), type: "divider" })
      i += 1
      continue
    }

    // Heading
    const headingMatch = line.match(/^(#{1,3})\s+(.*)$/)
    if (headingMatch) {
      const level = headingMatch[1].length as 1 | 2 | 3
      const text = headingMatch[2]
      blocks.push({
        id: blockId(),
        type: "heading",
        level,
        content: text ? [{ type: "text", text, marks: [] }] : [],
      })
      i += 1
      continue
    }

    // Table
    if (isTableStart(lines, i)) {
      const tableLines: string[] = []
      while (i < lines.length && /^\|.*\|$/.test((lines[i] ?? "").trim())) {
        tableLines.push(lines[i] ?? "")
        i += 1
      }
      const allRows = tableLines.map(splitTableRow)
      // Drop the separator row (index 1)
      const rows = [allRows[0] ?? [], ...allRows.slice(2)]
      blocks.push(makeTableBlock(rows))
      continue
    }

    // Callout — `> [!variant]` followed by quoted lines
    const calloutMatch = line.match(/^>\s*\[!(\w+)\]\s*$/)
    if (calloutMatch) {
      const rawVariant = calloutMatch[1].toLowerCase()
      const variant = (
        ["info", "warning", "error", "success"].includes(rawVariant)
          ? rawVariant
          : "info"
      ) as "info" | "warning" | "error" | "success"
      const bodyLines: string[] = []
      i += 1
      while (i < lines.length && (lines[i] ?? "").startsWith(">")) {
        const bodyLine = (lines[i] ?? "").replace(/^>\s?/, "")
        bodyLines.push(bodyLine)
        i += 1
      }
      const text = bodyLines.join("\n")
      blocks.push({
        id: blockId(),
        type: "callout",
        variant,
        icon: "lightbulb",
        content: text ? [{ type: "text", text, marks: [] }] : [],
      })
      continue
    }

    // Quote
    if (line.startsWith(">")) {
      const quoteLines: string[] = []
      while (i < lines.length && (lines[i] ?? "").startsWith(">")) {
        quoteLines.push((lines[i] ?? "").replace(/^>\s?/, ""))
        i += 1
      }
      const text = quoteLines.join("\n")
      blocks.push({
        id: blockId(),
        type: "quote",
        content: text ? [{ type: "text", text, marks: [] }] : [],
      })
      continue
    }

    // Todo list (must come before generic bullet check)
    const todoMatch = line.match(/^[-*]\s+\[([ xX])\]\s+(.*)$/)
    if (todoMatch) {
      const items: { text: string; checked: boolean }[] = []
      while (i < lines.length) {
        const m = (lines[i] ?? "").match(/^[-*]\s+\[([ xX])\]\s+(.*)$/)
        if (!m) break
        items.push({ text: m[2], checked: m[1].toLowerCase() === "x" })
        i += 1
      }
      blocks.push({
        id: blockId(),
        type: "list",
        style: "todo",
        items: items.map((it) => ({
          id: blockId(),
          content: it.text ? [{ type: "text", text: it.text, marks: [] }] : [],
          checked: it.checked,
          children: [],
        })),
      })
      continue
    }

    // Bullet list
    if (/^[-*]\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^[-*]\s+/.test(lines[i] ?? "")) {
        // Don't pick up todo lines as plain bullets
        if (/^[-*]\s+\[([ xX])\]\s+/.test(lines[i] ?? "")) break
        items.push((lines[i] ?? "").replace(/^[-*]\s+/, ""))
        i += 1
      }
      blocks.push({
        id: blockId(),
        type: "list",
        style: "unordered",
        items: items.map((text) => ({
          id: blockId(),
          content: text ? [{ type: "text", text, marks: [] }] : [],
          children: [],
        })),
      })
      continue
    }

    // Ordered list
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^\d+\.\s+/.test(lines[i] ?? "")) {
        items.push((lines[i] ?? "").replace(/^\d+\.\s+/, ""))
        i += 1
      }
      blocks.push({
        id: blockId(),
        type: "list",
        style: "ordered",
        items: items.map((text) => ({
          id: blockId(),
          content: text ? [{ type: "text", text, marks: [] }] : [],
          children: [],
        })),
      })
      continue
    }

    // Image — `![alt](src)` on its own line
    const imageMatch = line.match(/^!\[([^\]]*)\]\(([^)]+)\)\s*$/)
    if (imageMatch) {
      blocks.push({
        id: blockId(),
        type: "image",
        src: imageMatch[2],
        alt: imageMatch[1],
        caption: [],
      })
      i += 1
      continue
    }

    // Paragraph — collect contiguous non-special lines
    const paragraphLines: string[] = []
    while (i < lines.length) {
      const next = lines[i] ?? ""
      if (!next.trim()) break
      if (/^```/.test(next)) break
      if (next.trim() === "$$") break
      if (/^---+$/.test(next.trim())) break
      if (/^(#{1,3})\s+/.test(next)) break
      if (/^[-*]\s+/.test(next)) break
      if (/^\d+\.\s+/.test(next)) break
      if (next.startsWith(">")) break
      if (isTableStart(lines, i)) break
      if (/^!\[([^\]]*)\]\(([^)]+)\)\s*$/.test(next)) break
      paragraphLines.push(next)
      i += 1
    }
    const text = paragraphLines.join("\n")
    blocks.push({
      id: blockId(),
      type: "paragraph",
      content: text ? [{ type: "text", text, marks: [] }] : [],
    })
  }

  return blocks.length > 0 ? blocks : [makeBlock("paragraph")]
}
