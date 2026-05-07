/**
 * Block content schema.
 *
 * Defines the canonical shape of structured block content. Content is an
 * array of Block objects, each with a `type` discriminator. Blocks contain
 * inline content via `InlineNode` arrays that carry text with optional
 * formatting marks.
 */

import { z } from "zod"

// ---------------------------------------------------------------------------
// Marks — inline formatting applied to text spans
// ---------------------------------------------------------------------------

export const BoldMark = z.object({ type: z.literal("bold") })
export const ItalicMark = z.object({ type: z.literal("italic") })
export const StrikethroughMark = z.object({ type: z.literal("strikethrough") })
export const CodeMark = z.object({ type: z.literal("code") })
export const LinkMark = z.object({
  type: z.literal("link"),
  href: z.string().url(),
})

export const Mark = z.discriminatedUnion("type", [
  BoldMark,
  ItalicMark,
  StrikethroughMark,
  CodeMark,
  LinkMark,
])

export type Mark = z.infer<typeof Mark>

// ---------------------------------------------------------------------------
// Inline nodes — the leaf content inside blocks
// ---------------------------------------------------------------------------

/** Plain text with optional formatting marks. */
export const TextNode = z.object({
  type: z.literal("text"),
  text: z.string(),
  marks: z.array(Mark).default([]),
})

/** An @mention referencing a user, team, or channel. */
export const MentionNode = z.object({
  type: z.literal("mention"),
  entityType: z.enum(["user", "team", "channel"]),
  entityId: z.string().min(1),
  label: z.string(),
})

/** A rendered date chip that stores an ISO timestamp. */
export const DateNode = z.object({
  type: z.literal("date"),
  date: z.string().datetime(),
  format: z.enum(["date", "datetime", "relative"]).default("date"),
})

/**
 * A clickable reference to any workspace entity (task, project,
 * document, etc.). Richer than a plain link — the renderer can
 * show status, icon, or preview on hover.
 */
export const EntityRefNode = z.object({
  type: z.literal("entity-ref"),
  entityType: z.string().min(1),
  entityId: z.string().min(1),
  label: z.string(),
})

/** A named emoji (e.g. ":rocket:"). Enables custom workspace emoji later. */
export const EmojiNode = z.object({
  type: z.literal("emoji"),
  name: z.string().min(1).max(64),
})

/** Inline math expression rendered with KaTeX. */
export const InlineMathNode = z.object({
  type: z.literal("inline-math"),
  expression: z.string().min(1).max(10_000),
})

export const InlineNode = z.discriminatedUnion("type", [
  TextNode,
  MentionNode,
  DateNode,
  EntityRefNode,
  EmojiNode,
  InlineMathNode,
])

export type InlineNode = z.infer<typeof InlineNode>

// ---------------------------------------------------------------------------
// Block types
// ---------------------------------------------------------------------------

const blockId = z.string().min(1)

export const ParagraphBlock = z.object({
  id: blockId,
  type: z.literal("paragraph"),
  content: z.array(InlineNode).default([]),
})

export const HeadingBlock = z.object({
  id: blockId,
  type: z.literal("heading"),
  level: z.union([z.literal(1), z.literal(2), z.literal(3)]),
  content: z.array(InlineNode).default([]),
})

/** A single item within a ListBlock. Supports nesting for sub-lists. */
export const ListItem: z.ZodType<{
  id: string
  content: InlineNode[]
  checked?: boolean
  children: unknown[]
}> = z.lazy(() =>
  z.object({
    id: blockId,
    content: z.array(InlineNode).default([]),
    checked: z.boolean().optional(),
    children: z.array(ListItem).default([]),
  }),
)

export const ListBlock = z.object({
  id: blockId,
  type: z.literal("list"),
  style: z.enum(["ordered", "unordered", "todo"]),
  items: z.array(ListItem),
})

export const CodeBlock = z.object({
  id: blockId,
  type: z.literal("code"),
  language: z.string().max(50).default(""),
  code: z.string().max(100_000),
})

export const QuoteBlock = z.object({
  id: blockId,
  type: z.literal("quote"),
  content: z.array(InlineNode).default([]),
})

export const CalloutBlock = z.object({
  id: blockId,
  type: z.literal("callout"),
  variant: z.enum(["info", "warning", "error", "success"]),
  icon: z.string().optional(),
  color: z
    .string()
    .regex(/^#[0-9a-fA-F]{6}$/)
    .optional(),
  content: z.array(InlineNode).default([]),
})

export const DividerBlock = z.object({
  id: blockId,
  type: z.literal("divider"),
})

export const ImageBlock = z.object({
  id: blockId,
  type: z.literal("image"),
  src: z.string().min(1),
  alt: z.string().default(""),
  caption: z.array(InlineNode).default([]),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
})

export const TableBlock = z.object({
  id: blockId,
  type: z.literal("table"),
  columnWidths: z.array(z.number()).optional(),
  rows: z.array(
    z.object({
      id: blockId,
      cells: z.array(
        z.object({
          id: blockId,
          content: z.array(InlineNode).default([]),
          header: z.boolean().default(false),
        }),
      ),
    }),
  ),
})

export const EmbedBlock = z.object({
  id: blockId,
  type: z.literal("embed"),
  url: z.string().url(),
  title: z.string().default(""),
  description: z.string().default(""),
  thumbnail: z.string().optional(),
})

/**
 * Math block — a standalone rendered equation using KaTeX or similar.
 * For inline math within a paragraph, use the InlineMathNode instead.
 */
export const MathBlock = z.object({
  id: blockId,
  type: z.literal("math"),
  expression: z.string().min(1).max(10_000),
})

/**
 * Toggle block — an expandable/collapsible section.
 *
 * The summary is always visible; children are shown when expanded.
 * Children are a recursive Content array so any block type can nest
 * inside a toggle.
 *
 * The `z.lazy` wraps ONLY the recursive `children` field (rather than
 * the whole object). Wrapping the whole schema as a `ZodLazy` would
 * leave `propValues` undefined on the schema, which Zod 4 needs to
 * include the block in `z.discriminatedUnion("type", ...)` below.
 */
export const ToggleBlock: z.ZodObject<{
  id: typeof blockId
  type: z.ZodLiteral<"toggle">
  summary: z.ZodDefault<z.ZodArray<typeof InlineNode>>
  children: z.ZodType<unknown[]>
}> = z.object({
  id: blockId,
  type: z.literal("toggle"),
  summary: z.array(InlineNode).default([]),
  children: z.lazy(() => z.array(Block).default([])) as z.ZodType<unknown[]>,
})

// ---------------------------------------------------------------------------
// Block union — the discriminated union of all block types
// ---------------------------------------------------------------------------

// Explicit type annotation: Block is referenced from ToggleBlock's
// `children` via z.lazy, which makes the inference circular. We declare
// the schema as `z.ZodType<Block>` (using the hand-written union below)
// so consumers get correct narrowing on `.parse(...)`.
//
// The `as unknown as z.ZodType<Block>` cast is needed because Zod 4's
// `ZodDiscriminatedUnion<...>` return type isn't structurally assignable
// to `z.ZodType<Block>` — the variance of internal `$ZodTypeInternals`
// trips on the recursive Toggle.children type.
export const Block: z.ZodType<Block> = z.discriminatedUnion("type", [
  ParagraphBlock,
  HeadingBlock,
  ListBlock,
  CodeBlock,
  QuoteBlock,
  CalloutBlock,
  DividerBlock,
  ImageBlock,
  TableBlock,
  EmbedBlock,
  MathBlock,
  ToggleBlock,
]) as unknown as z.ZodType<Block>

/**
 * Hand-written Block type because `z.infer` on discriminated unions
 * containing `z.lazy` resolves to `unknown` in TypeScript 5.9 + Zod 4.
 */
export type Block =
  | { id: string; type: "paragraph"; content: InlineNode[] }
  | { id: string; type: "heading"; level: 1 | 2 | 3; content: InlineNode[] }
  | {
      id: string
      type: "list"
      style: "ordered" | "unordered" | "todo"
      items: ListItemType[]
    }
  | { id: string; type: "code"; language: string; code: string }
  | { id: string; type: "quote"; content: InlineNode[] }
  | {
      id: string
      type: "callout"
      variant: "info" | "warning" | "error" | "success"
      icon?: string
      color?: string
      content: InlineNode[]
    }
  | { id: string; type: "divider" }
  | {
      id: string
      type: "image"
      src: string
      alt: string
      caption: InlineNode[]
      width?: number
      height?: number
    }
  | {
      id: string
      type: "table"
      columnWidths?: number[]
      rows: {
        id: string
        cells: { id: string; content: InlineNode[]; header: boolean }[]
      }[]
    }
  | {
      id: string
      type: "embed"
      url: string
      title: string
      description: string
      thumbnail?: string
    }
  | { id: string; type: "math"; expression: string }
  | { id: string; type: "toggle"; summary: InlineNode[]; children: Block[] }

type ListItemType = {
  id: string
  content: InlineNode[]
  checked?: boolean
  children: ListItemType[]
}

// ---------------------------------------------------------------------------
// Document content — the top-level array validated on API write
// ---------------------------------------------------------------------------

/** Maximum number of blocks in a single document/note. */
export const MAX_BLOCKS = 5_000

export const Content = z.array(Block).max(MAX_BLOCKS)

export type Content = z.infer<typeof Content>
