import { getInlineContent, setInlineContent, sliceInline } from "./inline.js";
import { plainText } from "./model.js";
import type { Block, InlineNode, Mark } from "./schema.js";

const ignored = new Set([
  "SCRIPT",
  "STYLE",
  "NOSCRIPT",
  "TEMPLATE",
  "IFRAME",
  "OBJECT",
  "EMBED",
  "SVG",
  "MATH",
  "INPUT",
  "SELECT",
  "TEXTAREA",
  "BUTTON",
]);
const boundaries = new Set([
  "P",
  "DIV",
  "SECTION",
  "ARTICLE",
  "HEADER",
  "FOOTER",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "BLOCKQUOTE",
  "UL",
  "OL",
  "LI",
  "PRE",
  "HR",
  "TABLE",
  "TR",
]);

/** Import clipboard HTML into data only. The template stays inert and is never
 * attached to a document. No HTML, style, event handler or remote image survives.
 * Browser-only; importing the module itself remains safe on the server.
 */
export function parseClipboardHtml(
  html: string,
  doc: Document = document,
): Block[] {
  if (html.length > 1_000_000) return [];
  const template = doc.createElement("template");
  template.innerHTML = html;
  const result: Block[] = [];
  let rejected = false;
  let pending: InlineNode[] = [];
  const id = () => crypto.randomUUID();
  function flush(
    type: "paragraph" | "heading" | "quote" | "list" = "paragraph",
    element?: Element,
  ) {
    const content = pending;
    pending = [];
    if (!plainText(content).trim()) return;
    if (type === "heading")
      result.push({
        id: id(),
        type,
        level: Math.min(3, Number(element?.tagName.slice(1))) as 1 | 2 | 3,
        content,
      });
    else if (type === "list")
      result.push({
        id: id(),
        type,
        style:
          element?.parentElement?.tagName === "OL" ? "ordered" : "unordered",
        items: [{ id: id(), content, children: [] }],
      });
    else result.push({ id: id(), type, content });
  }
  function text(value: string, marks: Mark[]) {
    if (!value) return;
    const previous = pending.at(-1);
    if (
      previous?.type === "text" &&
      JSON.stringify(previous.marks) === JSON.stringify(marks)
    )
      previous.text += value;
    else pending.push({ type: "text", text: value, marks });
  }
  type Context = {
    type: "paragraph" | "heading" | "quote" | "list";
    element?: Element;
  };
  function walk(
    node: Node,
    marks: Mark[] = [],
    context: Context = { type: "paragraph" },
    depth = 0,
  ) {
    if (depth > 128) {
      rejected = true;
      return;
    }
    if (node.nodeType === 3) {
      text((node.textContent ?? "").replace(/[\t\r\n ]+/g, " "), marks);
      return;
    }
    if (node.nodeType !== 1) return;
    const element = node as Element;
    if (element.namespaceURI !== "http://www.w3.org/1999/xhtml") return;
    const tag = element.tagName;
    if (ignored.has(tag)) return;
    if (tag === "IMG") {
      text(element.getAttribute("alt") ?? "", marks);
      return;
    }
    if (tag === "BR") {
      text("\n", marks);
      return;
    }
    const boundary = boundaries.has(tag);
    if (boundary) flush(context.type, context.element);
    if (tag === "HR") {
      result.push({ id: id(), type: "divider" });
      return;
    }
    if (tag === "PRE") {
      // textContent would include script/style contents; extract visible code only.
      function codeText(node: Node, depth = 0): string {
        if (depth > 128) {
          rejected = true;
          return "";
        }
        if (node.nodeType === 3) return node.textContent ?? "";
        if (node.nodeType !== 1) return "";
        const element = node as Element;
        if (
          element.namespaceURI !== "http://www.w3.org/1999/xhtml" ||
          ignored.has(element.tagName)
        )
          return "";
        if (element.tagName === "BR") return "\n";
        return Array.from(node.childNodes, (child) =>
          codeText(child, depth + 1),
        ).join("");
      }
      const code = codeText(element);
      if (code.length > 100_000) rejected = true;
      else result.push({ id: id(), type: "code", language: "", code });
      return;
    }
    const next = [...marks];
    const markType =
      tag === "B" || tag === "STRONG"
        ? "bold"
        : tag === "I" || tag === "EM"
          ? "italic"
          : tag === "CODE"
            ? "code"
            : undefined;
    if (markType && !next.some((mark) => mark.type === markType))
      next.push({ type: markType });
    if (tag === "A") {
      try {
        const url = new URL(element.getAttribute("href") ?? "");
        if (["https:", "http:", "mailto:"].includes(url.protocol))
          next.push({ type: "link", href: url.href });
      } catch {
        /* Relative and invalid links keep their visible text. */
      }
    }
    const ownContext: Context = /^H[1-6]$/.test(tag)
      ? { type: "heading", element }
      : tag === "BLOCKQUOTE"
        ? { type: "quote", element }
        : tag === "LI"
          ? { type: "list", element }
          : context;
    for (const child of element.childNodes)
      walk(child, next, ownContext, depth + 1);
    if (tag === "TD" || tag === "TH") text("\t", marks);
    if (boundary) flush(ownContext.type, ownContext.element);
  }
  for (const child of template.content.childNodes) walk(child);
  flush();
  return !rejected && result.length <= 5000 ? result : [];
}

/** Replace a textarea selection without losing surrounding structured content.
 * Returns null for literal/code/table or ambiguous multi-item list destinations.
 * Offsets use the browser's UTF-16 selection convention.
 */
export function pasteBlocks(
  block: Block,
  imported: Block[],
  start: number,
  end: number,
): { blocks: Block[]; focusId: string; caret: number } | null {
  const content = getInlineContent(block);
  if (!content || !imported.length) return null;
  const length = plainText(content).length;
  start = Math.max(0, Math.min(length, start));
  end = Math.max(start, Math.min(length, end));
  const prefix = sliceInline(content, 0, start);
  const suffix = sliceInline(content, end, length);
  const single = imported[0];
  if (imported.length === 1 && single.type === "paragraph") {
    return {
      blocks: [
        setInlineContent(block, [...prefix, ...single.content, ...suffix]),
      ],
      focusId: block.id,
      caret: start + plainText(single.content).length,
    };
  }
  const next = [...imported];
  // Keep the destination block identity/type when text remains before the paste.
  if (prefix.length && next[0].type === "paragraph")
    next[0] = setInlineContent(block, [...prefix, ...next[0].content]);
  else if (prefix.length) next.unshift(setInlineContent(block, prefix));
  else next[0] = { ...next[0], id: block.id };
  const last = next.at(-1)!;
  const tail = getInlineContent(last);
  if (tail) {
    next[next.length - 1] = setInlineContent(last, [...tail, ...suffix]);
    return { blocks: next, focusId: last.id, caret: plainText(tail).length };
  }
  const paragraph: Block = {
    id: crypto.randomUUID(),
    type: "paragraph",
    content: suffix,
  };
  next.push(paragraph);
  return { blocks: next, focusId: paragraph.id, caret: 0 };
}
