import { describe, expect, it } from "bun:test"
import { plainText, setBlockText, updateInlineText } from "./model.js"
import type { InlineNode } from "./schema.js"

const bold = [{ type: "bold" as const }]
const italic = [{ type: "italic" as const }]
const text = (value: string, marks: { type: "bold" | "italic" }[] = []): InlineNode => ({ type: "text", text: value, marks })

describe("format-preserving plain text updates", () => {
  it("preserves formatting outside an edit and inherits the edited span's marks", () => {
    const nodes = [text("Hello", bold), text(" world", italic)]
    expect(updateInlineText(nodes, "Hello brave world")).toEqual([text("Hello", bold), text(" brave world", italic)])
    expect(updateInlineText(nodes, "Hallo world")).toEqual([text("Hallo", bold), text(" world", italic)])
    expect(nodes).toEqual([text("Hello", bold), text(" world", italic)])
  })
  it("keeps untouched mentions and dates while editing nearby text", () => {
    const mention: InlineNode = { type: "mention", entityType: "user", entityId: "user-1", label: "Alice" }
    const date: InlineNode = { type: "date", date: "2026-09-28T00:00:00.000Z", format: "date" }
    const nodes = [text("Hi "), mention, text(" on "), date]
    const updated = updateInlineText(nodes, "Hello Alice on 2026-09-28T00:00:00.000Z")
    expect(updated).toContain(mention)
    expect(updated).toContain(date)
    expect(plainText(updated)).toBe("Hello Alice on 2026-09-28T00:00:00.000Z")
  })
  it("does not keep a stale reference when its label is edited", () => {
    const nodes: InlineNode[] = [{ type: "mention", entityType: "user", entityId: "user-1", label: "Alice" }]
    expect(updateInlineText(nodes, "Alison")).toEqual([text("Alison")])
  })
  it("does not split surrogate pairs when replacing emoji", () => {
    expect(updateInlineText([text("A😀B", bold)], "A😁B")).toEqual([text("A😁B", bold)])
    expect(updateInlineText([text("😀", bold), text("a", italic)], "😁a")).toEqual([text("😁", bold), text("a", italic)])
  })
  it("handles deletion across differently marked spans, empty input and no-op identity", () => {
    const nodes = [text("Hello", bold), text(" world", italic)]
    expect(updateInlineText(nodes, "Hld")).toEqual([text("H", bold), text("ld", italic)])
    expect(updateInlineText(nodes, "")).toEqual([])
    expect(updateInlineText([], "New")).toEqual([text("New")])
    expect(updateInlineText(nodes, "Hello world")).toBe(nodes)
  })
  it("preserves links through edits and wires the behavior into block text updates", () => {
    const nodes: InlineNode[] = [{ type: "text", text: "Website", marks: [{ type: "link", href: "https://example.com" }, { type: "bold" }] }]
    const updated = setBlockText({ id: "p1", type: "paragraph", content: nodes }, "Our Website")
    expect(updated).toEqual({ id: "p1", type: "paragraph", content: [{ ...nodes[0], text: "Our Website" }] })
  })
})
