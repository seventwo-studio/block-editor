import { plainText } from "./model.js";
import type { Block, InlineNode, Mark } from "./schema.js";

export function getInlineContent(block: Block): InlineNode[] | null {
  if (
    ["paragraph", "heading", "quote", "callout"].includes(block.type) &&
    "content" in block
  )
    return block.content;
  if (
    block.type === "list" &&
    block.items.length === 1 &&
    block.items[0].children.length === 0
  )
    return block.items[0].content;
  return null;
}

export function setInlineContent(block: Block, content: InlineNode[]): Block {
  if (block.type === "list")
    return { ...block, items: [{ ...block.items[0], content }] };
  return { ...block, content } as Block;
}

/** Browser selections and these ranges use UTF-16 offsets. */
export function sliceInline(
  nodes: InlineNode[],
  start: number,
  end: number,
): InlineNode[] {
  let offset = 0;
  return nodes.flatMap((node) => {
    const value = plainText([node]);
    const from = Math.max(0, start - offset);
    const to = Math.min(value.length, end - offset);
    offset += value.length;
    if (from >= to) return [];
    if (from === 0 && to === value.length) return [node];
    return [
      node.type === "text"
        ? { ...node, text: value.slice(from, to) }
        : { type: "text" as const, text: value.slice(from, to), marks: [] },
    ];
  });
}

export function replaceInlineRange(
  nodes: InlineNode[],
  start: number,
  end: number,
  inserted: InlineNode[],
): InlineNode[] {
  const result: InlineNode[] = [];
  for (const node of [
    ...sliceInline(nodes, 0, start),
    ...inserted,
    ...sliceInline(nodes, end, plainText(nodes).length),
  ]) {
    const previous = result.at(-1);
    if (
      node.type === "text" &&
      previous?.type === "text" &&
      JSON.stringify(node.marks) === JSON.stringify(previous.marks)
    )
      result[result.length - 1] = {
        ...previous,
        text: previous.text + node.text,
      };
    else result.push(node);
  }
  return result;
}

export function toggleInlineMark(
  nodes: InlineNode[],
  start: number,
  end: number,
  mark: Mark,
): InlineNode[] {
  if (start === end) return nodes;
  const selected = sliceInline(nodes, start, end);
  const texts = selected.filter((node) => node.type === "text");
  const remove =
    mark.type !== "link" &&
    texts.length > 0 &&
    texts.every((node) =>
      node.marks.some(
        (existing) => JSON.stringify(existing) === JSON.stringify(mark),
      ),
    );
  return replaceInlineRange(
    nodes,
    start,
    end,
    selected.map((node) =>
      node.type === "text"
        ? {
            ...node,
            marks: [
              ...node.marks.filter((existing) => existing.type !== mark.type),
              ...(remove ? [] : [mark]),
            ],
          }
        : node,
    ),
  );
}

export function safeLink(href: string): string | null {
  try {
    const url = new URL(href);
    return ["https:", "http:", "mailto:"].includes(url.protocol)
      ? url.href
      : null;
  } catch {
    return null;
  }
}
