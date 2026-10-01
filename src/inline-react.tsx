import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type KeyboardEvent,
} from "react";
import { plainText, updateInlineText } from "./model.js";
import {
  replaceInlineRange,
  safeLink,
  sliceInline,
  toggleInlineMark,
} from "./inline.js";
import type { InlineNode, Mark } from "./schema.js";

export type TextSelection = { start: number; end: number; backward?: boolean };

export function inlineSelection(root: HTMLElement): TextSelection | null {
  const selection = root.ownerDocument.getSelection();
  if (!selection?.rangeCount) return null;
  const range = selection.getRangeAt(0);
  if (
    !root.contains(range.startContainer) ||
    !root.contains(range.endContainer)
  )
    return null;
  const prefix = range.cloneRange();
  prefix.selectNodeContents(root);
  prefix.setEnd(range.startContainer, range.startOffset);
  const start = prefix.toString().length;
  return { start, end: start + range.toString().length,
    backward: !range.collapsed && selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset };
}

export function selectInline(root: HTMLElement, start: number, end = start, backward = false) {
  const doc = root.ownerDocument;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const points: { node: Node; from: number; to: number }[] = [];
  let offset = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    points.push({
      node,
      from: offset,
      to: offset + (node.textContent?.length ?? 0),
    });
    offset += node.textContent?.length ?? 0;
  }
  const point = (at: number) => {
    at = Math.min(offset, Math.max(0, at));
    const item = points.find((item) => item.to >= at);
    return item
      ? { node: item.node, offset: at - item.from }
      : { node: root as Node, offset: 0 };
  };
  const a = point(start),
    b = point(end);
  const range = doc.createRange();
  range.setStart(a.node, a.offset);
  range.setEnd(b.node, b.offset);
  const selection = doc.getSelection();
  if (backward && selection) {
    selection.setBaseAndExtent(b.node, b.offset, a.node, a.offset);
    return;
  }
  selection?.removeAllRanges();
  selection?.addRange(range);
}

/** Render only schema-derived nodes, never browser-mutated HTML. */
function renderInline(root: HTMLElement, content: InlineNode[]) {
  const doc = root.ownerDocument;
  const nodes = content.map((inline) => {
    let node: Node = doc.createTextNode(plainText([inline]));
    if (inline.type === "text") {
      for (const mark of inline.marks) {
        const tag =
          mark.type === "bold"
            ? "strong"
            : mark.type === "italic"
              ? "em"
              : mark.type === "code"
                ? "code"
                : mark.type === "strikethrough"
                  ? "s"
                  : "a";
        const href = mark.type === "link" ? safeLink(mark.href) : null;
        if (mark.type === "link" && !href) continue;
        const element = doc.createElement(tag);
        if (mark.type === "link" && href) {
          element.setAttribute("href", href);
          element.setAttribute("title", mark.href);
        }
        element.append(node);
        node = element;
      }
    }
    return node;
  });
  root.replaceChildren(...nodes);
}

export function InlineEditor({
  content,
  placeholder,
  autoFocus,
  focused,
  inputRef,
  onFocus,
  onKeyDown,
  onPaste,
  onChange,
  onEnter,
  onHistory,
  mapSelection,
  onCompositionChange,
  readOnly = false,
}: {
  content: InlineNode[];
  placeholder: string;
  autoFocus: boolean;
  focused: boolean;
  inputRef: (node: HTMLDivElement | null) => void;
  onFocus: () => void;
  onKeyDown: (event: KeyboardEvent<HTMLElement>) => void;
  onPaste: (event: ClipboardEvent<HTMLElement>) => void;
  onChange: (content: InlineNode[]) => void;
  onEnter: (target: HTMLElement) => void;
  onHistory: (direction: "undo" | "redo") => void;
  mapSelection?: (selection: TextSelection | null) => TextSelection | null;
  onCompositionChange?: (active: boolean) => void;
  readOnly?: boolean;
}) {
  const rootRef = useRef<HTMLDivElement>(null);
  const composing = useRef(false);
  const saved = useRef<TextSelection>({ start: 0, end: 0 });
  const restore = useRef<TextSelection | null>(null);
  const typingMarks = useRef<Mark[] | null>(null);
  const compositionRange = useRef<TextSelection | null>(null);
  const latest = useRef({ content, onChange, onEnter, onHistory, readOnly });
  latest.current = { content, onChange, onEnter, onHistory, readOnly };
  const [linkOpen, setLinkOpen] = useState(false);
  const [href, setHref] = useState("");
  const [error, setError] = useState("");
  const [activeMarks, setActiveMarks] = useState<string[]>([]);

  function remember(resetTyping = false) {
    const root = rootRef.current;
    if (!root) return;
    const range = inlineSelection(root);
    if (!range) return;
    saved.current = range;
    if (resetTyping) typingMarks.current = null;
    const selected = sliceInline(
      latest.current.content,
      range.start === range.end ? Math.max(0, range.start - 1) : range.start,
      range.end,
    );
    const texts = selected.filter((node) => node.type === "text");
    setActiveMarks(
      typingMarks.current?.map((mark) => mark.type) ??
        ["bold", "italic", "code", "link"].filter(
          (type) =>
            texts.length > 0 &&
            texts.every((node) =>
              node.marks.some((mark) => mark.type === type),
            ),
        ),
    );
  }

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root || composing.current) return;
    const candidate = root.ownerDocument.activeElement === root ? restore.current ?? inlineSelection(root) : null;
    const selection = mapSelection ? mapSelection(candidate) : candidate;
    renderInline(root, content);
    if (selection) selectInline(root, selection.start, selection.end, selection.backward);
    restore.current = null;
  }, [content]);

  useEffect(() => {
    const root = rootRef.current;
    if (autoFocus && root && root.ownerDocument.activeElement !== root)
      root.focus();
  }, [autoFocus]);
  // biome-ignore lint/correctness/useExhaustiveDependencies: Native listeners read current props through latest and stable refs.
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    const selectionChanged = () => remember();
    root.ownerDocument.addEventListener("selectionchange", selectionChanged);
    const beforeInput = (event: InputEvent) => {
      if (latest.current.readOnly) { event.preventDefault(); return; }
      if (event.isComposing || composing.current) return;
      if (event.inputType === "insertParagraph") {
        event.preventDefault();
        latest.current.onEnter(root);
      } else if (event.inputType === "insertLineBreak") {
        event.preventDefault();
        insertNewline();
      } else if (
        event.inputType === "historyUndo" ||
        event.inputType === "historyRedo"
      ) {
        event.preventDefault();
        latest.current.onHistory(
          event.inputType === "historyUndo" ? "undo" : "redo",
        );
      } else if (
        event.inputType === "formatBold" ||
        event.inputType === "formatItalic"
      ) {
        event.preventDefault();
        format({ type: event.inputType === "formatBold" ? "bold" : "italic" });
      } else if (
        [
          "insertText",
          "insertReplacementText",
          "deleteContentBackward",
          "deleteContentForward",
          "deleteWordBackward",
          "deleteWordForward",
          "deleteByCut",
        ].includes(event.inputType)
      ) {
        if (event.inputType.startsWith("insert") && event.data === null) return;
        const targets = event.getTargetRanges();
        const target = targets[0];
        let selection = inlineSelection(root);
        if (target) {
          if (
            !root.contains(target.startContainer) ||
            !root.contains(target.endContainer)
          ) {
            event.preventDefault();
            return;
          }
          const prefix = root.ownerDocument.createRange();
          prefix.selectNodeContents(root);
          prefix.setEnd(target.startContainer, target.startOffset);
          const start = prefix.toString().length;
          prefix.setEnd(target.endContainer, target.endOffset);
          selection = { start, end: prefix.toString().length };
        }
        if (!selection) {
          event.preventDefault();
          return;
        }
        if (
          event.inputType.startsWith("delete") &&
          !target &&
          selection.start === selection.end
        )
          return;
        event.preventDefault();
        const text = event.inputType.startsWith("delete")
          ? ""
          : (event.data ?? "");
        const content = latest.current.content;
        const at =
          selection.start === selection.end
            ? Math.max(0, selection.start - 1)
            : selection.start;
        const surrounding = sliceInline(content, at, at + 1)[0];
        const marks =
          typingMarks.current ??
          (surrounding?.type === "text" ? surrounding.marks : []);
        restore.current = {
          start: selection.start + text.length,
          end: selection.start + text.length,
        };
        latest.current.onChange(
          replaceInlineRange(
            content,
            selection.start,
            selection.end,
            text ? [{ type: "text", text, marks }] : [],
          ),
        );
      }
    };
    root.addEventListener("beforeinput", beforeInput);
    return () => {
      root.ownerDocument.removeEventListener(
        "selectionchange",
        selectionChanged,
      );
      root.removeEventListener("beforeinput", beforeInput);
    };
  }, []);

  function format(mark: Mark) {
    const root = rootRef.current;
    if (!root) return;
    const range = inlineSelection(root) ?? saved.current;
    if (range.start === range.end) {
      const preceding = sliceInline(
        latest.current.content,
        Math.max(0, range.start - 1),
        range.start,
      ).at(-1);
      const current =
        typingMarks.current ??
        (preceding?.type === "text" ? preceding.marks : []);
      typingMarks.current = current.some((item) => item.type === mark.type)
        ? current.filter((item) => item.type !== mark.type)
        : [...current, mark];
      setActiveMarks(typingMarks.current.map((item) => item.type));
    } else {
      restore.current = range;
      latest.current.onChange(
        toggleInlineMark(latest.current.content, range.start, range.end, mark),
      );
    }
    root.focus();
    selectInline(root, range.start, range.end);
  }

  function insertNewline() {
    const { content, onChange } = latest.current;
    const root = rootRef.current;
    if (!root) return;
    const range = inlineSelection(root) ?? saved.current;
    const previous = sliceInline(
      content,
      Math.max(0, range.start - 1),
      range.start,
    ).at(-1);
    restore.current = { start: range.start + 1, end: range.start + 1 };
    onChange(
      replaceInlineRange(content, range.start, range.end, [
        {
          type: "text",
          text: "\n",
          marks:
            typingMarks.current ??
            (previous?.type === "text" ? previous.marks : []),
        },
      ]),
    );
  }

  return (
    <div className="s2be-inline">
      {focused && !readOnly && (
        <div
          className="s2be-inline-toolbar"
          role="toolbar"
          aria-label="Text formatting"
        >
          {(["bold", "italic", "code"] as const).map((type) => (
            <button
              key={type}
              type="button"
              aria-label={
                type === "code"
                  ? "Inline code"
                  : type[0].toUpperCase() + type.slice(1)
              }
              aria-pressed={activeMarks.includes(type)}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => format({ type })}
            >
              {type === "bold" ? (
                <strong>B</strong>
              ) : type === "italic" ? (
                <em>I</em>
              ) : (
                "<>"
              )}
            </button>
          ))}
          <button
            type="button"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => {
              remember();
              setLinkOpen(!linkOpen);
              setError("");
            }}
          >
            Link
          </button>
        </div>
      )}
      {focused && !readOnly && linkOpen && (
        <form
          className="s2be-link-form"
          onSubmit={(event) => {
            event.preventDefault();
            const safe = safeLink(href);
            if (!safe) {
              setError("Use an absolute http, https or mailto address.");
              return;
            }
            if (saved.current.start === saved.current.end) {
              setError("Select the text to link first.");
              return;
            }
            format({ type: "link", href: safe });
            setLinkOpen(false);
          }}
        >
          <input
            aria-label="Link address"
            value={href}
            onChange={(event) => setHref(event.target.value)}
            placeholder="https://example.com"
          />
          <button type="submit">Apply link</button>
          <button
            type="button"
            onClick={() => {
              const range = saved.current;
              const selected = sliceInline(content, range.start, range.end).map(
                (node) =>
                  node.type === "text"
                    ? {
                        ...node,
                        marks: node.marks.filter(
                          (mark) => mark.type !== "link",
                        ),
                      }
                    : node,
              );
              restore.current = range;
              onChange(
                replaceInlineRange(content, range.start, range.end, selected),
              );
              setLinkOpen(false);
              rootRef.current?.focus();
            }}
          >
            Remove link
          </button>
          <button
            type="button"
            onClick={() => {
              setLinkOpen(false);
              rootRef.current?.focus();
            }}
          >
            Cancel
          </button>
          {error && <span role="alert">{error}</span>}
        </form>
      )}
      {/* biome-ignore lint/a11y/useSemanticElements: Rich text needs a contenteditable surface, not a plain input. */}
      <div
        tabIndex={0}
        ref={(node) => {
          rootRef.current = node;
          inputRef(node);
        }}
        className="s2be-input s2be-rich-input"
        role="textbox"
        aria-label={placeholder || "Block text"}
        aria-multiline="true"
        data-placeholder={placeholder}
        contentEditable={!readOnly}
        aria-readonly={readOnly}
        suppressContentEditableWarning
        onFocus={onFocus}
        onClick={(event) => {
          if ((event.target as HTMLElement).closest("a"))
            event.preventDefault();
          remember(true);
        }}
        onKeyUp={(event) => {
          if (
            event.key.startsWith("Arrow") ||
            event.key === "Home" ||
            event.key === "End"
          )
            remember(true);
        }}
        onKeyDown={(event) => {
          if (readOnly) return;
          if (event.nativeEvent.isComposing || composing.current) return;
          const key = event.key.toLowerCase();
          if (
            (event.metaKey || event.ctrlKey) &&
            ["b", "i", "e", "k"].includes(key)
          ) {
            event.preventDefault();
            if (key === "k") {
              remember();
              setLinkOpen(true);
            } else
              format({
                type: key === "b" ? "bold" : key === "i" ? "italic" : "code",
              });
            return;
          }
          if (event.key === "Enter" && event.shiftKey) {
            event.preventDefault();
            insertNewline();
            return;
          }
          onKeyDown(event);
        }}
        onPaste={event => { if (readOnly) event.preventDefault(); else onPaste(event); }}
        onDrop={(event) => event.preventDefault()}
        onCompositionStart={(event) => {
          if (readOnly) return;
          composing.current = true;
          compositionRange.current = inlineSelection(event.currentTarget);
          onCompositionChange?.(true);
        }}
        onCompositionEnd={(event) => {
          composing.current = false;
          try {
            if (readOnly) return;
            const range = compositionRange.current;
            if (typingMarks.current && range && event.data) {
              restore.current = {
                start: range.start + event.data.length,
                end: range.start + event.data.length,
              };
              onChange(
                replaceInlineRange(content, range.start, range.end, [
                  { type: "text", text: event.data, marks: typingMarks.current },
                ]),
              );
            } else
              onChange(
                updateInlineText(content, event.currentTarget.textContent ?? ""),
              );
          } finally { onCompositionChange?.(false); }
        }}
        onInput={(event) => {
          if (readOnly || composing.current) return;
          onChange(
            updateInlineText(content, event.currentTarget.textContent ?? ""),
          );
        }}
      />
    </div>
  );
}
