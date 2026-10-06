import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type CSSProperties, type ReactNode, type KeyboardEvent } from "react";
import { SwiftEditorRuntime } from "./swift.js";
import { SwiftModernSession, type ModernAuthorCommand, type ModernDocument, type ModernField, type ModernNodeID, type ModernObject, type ModernPosition, type ModernTextRange, type ModernResult, type ModernNodes, type ModernBoundary, type ModernCollection, type ModernInsertionDescriptor, type ModernPolicy, type ModernSemanticTarget } from "./swift-modern.js";
import { ModernBrowserHost } from "./swift-modern-host.js";
import { inlineSelection, selectInline } from "./inline-react.js";

const key = (value: unknown) => JSON.stringify(value);
const object = (value: unknown): ModernObject => value && typeof value === "object" && !Array.isArray(value) ? value as ModernObject : {};
const array = (value: unknown): readonly ModernObject[] => Array.isArray(value) ? value as readonly ModernObject[] : [];
const text = (value: unknown): string => typeof value === "string" ? value : "";
function visible(nodes: readonly ModernObject[]): string { return nodes.map(node => node.type === "text" ? text(node.text) : text(node.label ?? node.date ?? node.expression ?? node.name)).join(""); }
function renderInline(root: HTMLElement, nodes: readonly ModernObject[] | string, open?: (id: string, type: string) => void): void {
  const fragment = root.ownerDocument.createDocumentFragment();
  if (typeof nodes === "string") fragment.append(root.ownerDocument.createTextNode(nodes));
  else for (const node of nodes) {
    if (node.type === "soft-break") { fragment.append(root.ownerDocument.createElement("br")); continue; }
    let element: Node = root.ownerDocument.createTextNode(node.type === "text" ? text(node.text) : visible([node]) || "Unavailable reference");
    if (node.type !== "text") {
      const reference = root.ownerDocument.createElement("span"); reference.contentEditable = "false"; reference.className = "modern-reference"; reference.setAttribute("role", "link"); reference.tabIndex = 0;
      reference.append(element); const activate = () => open?.(text(node.entityId), text(node.entityType)); reference.onclick = activate;
      reference.onkeydown = event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); activate(); } }; element = reference;
    } else for (const mark of array(node.marks)) {
      const tag = ({ bold: "strong", italic: "em", strikethrough: "s", code: "code", link: "a" } as Record<string, string>)[text(mark.type)] ?? "span";
      const wrapper = root.ownerDocument.createElement(tag);
      if (mark.type === "link" && /^(https?:\/\/|mailto:)/i.test(text(mark.href))) wrapper.setAttribute("href", text(mark.href));
      if (mark.type === "semantic-color") wrapper.dataset.ink = text(mark.value);
      if (mark.type === "semantic-background") wrapper.dataset.fill = text(mark.value);
      wrapper.append(element); element = wrapper;
    }
    fragment.append(element);
  }
  root.replaceChildren(fragment);
}

interface InputProps {
  session: SwiftModernSession; host?: ModernBrowserHost; field: ModernField; value: readonly ModernObject[] | string; label: string; readOnly: boolean;
  register: (field: ModernField, element: HTMLElement | null) => void;
  selected: (range: ModernTextRange, element: HTMLElement) => void;
  execute: (command: ModernAuthorCommand) => ModernResult;
  enter?: (range: ModernTextRange) => void; navigate?: (event: KeyboardEvent<HTMLDivElement>, range: ModernTextRange) => boolean;
  query: (field: ModernField, value: string, range: ModernTextRange, element: HTMLElement) => void;
  report: (error: unknown) => void; openReference?: (id: string, type: string) => void;
}
/** Native browser editing buffer. The shared engine receives a scalar-safe
 * minimal replacement, never a JavaScript reconstruction of the document. */
function ModernInput(props: InputProps) {
  const { session, field } = props, element = useRef<HTMLDivElement>(null), composing = useRef(false);
  const release = useRef<(() => void) | undefined>(undefined), before = useRef("");
  const anchors = useRef<ModernTextRange | undefined>(undefined), typing = useRef(crypto.randomUUID());
  const original = useRef<ModernTextRange | undefined>(undefined), rendered = useRef<string | undefined>(undefined);
  const pending = useRef(false), value = typeof props.value === "string" ? props.value : visible(props.value);
  const fieldKey = key(field);
  function selection(): ModernTextRange | undefined {
    const root = element.current; if (!root) return;
    const selected = inlineSelection(root); if (!selected) return;
    const previous = anchors.current;
    if (previous) {
      try {
        const start = session.resolvePosition(previous.start).offset, end = session.resolvePosition(previous.end).offset;
        if (Math.min(start, end) === selected.start && Math.max(start, end) === selected.end && (start > end) === !!selected.backward) return previous;
      } catch { /* A deleted field is handled by the retained draft path. */ }
    }
    return session.captureTextRange(field, selected.backward ? selected.end : selected.start, selected.backward ? selected.start : selected.end);
  }
  function capture(): void {
    if (composing.current || pending.current) return;
    try {
      const range = selection(); if (!range || !element.current) return;
      anchors.current = range; props.selected(range, element.current);
      const previous = session.localSelection();
      if (key(previous?.selection) !== key({ text: { _0: { start: range.start, end: range.end } } })) {
        session.setLocalSelection({ documentID: range.start.documentID, epoch: range.start.epoch, observed: range.observed,
          focus: { text: { _0: range.end } }, selection: { text: { _0: { start: range.start, end: range.end } } } });
        typing.current = crypto.randomUUID();
      }
    } catch (error) { props.report(error); }
  }
  function commit(): void {
    const root = element.current; if (!root || composing.current || pending.current) return;
    const next = root.textContent ?? "", old = before.current;
    if (next === old) { capture(); return; }
    const a = Array.from(old), b = Array.from(next); let prefix = 0, suffix = 0;
    while (prefix < Math.min(a.length, b.length) && a[prefix] === b[prefix]) prefix++;
    while (suffix < Math.min(a.length, b.length) - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++;
    const lower = a.slice(0, prefix).join("").length, upper = old.length - a.slice(a.length - suffix).join("").length;
    const replacement = b.slice(prefix, b.length - suffix).join("");
    let target: ModernTextRange | undefined;
    try {
      target = session.captureTextRange(field, lower, upper);
      const result = props.execute({ command: field.name === "title" ? "replaceTitle" : "replaceText", target, arguments: { text: replacement, typingGroup: typing.current } });
      if (result.status !== "applied" && result.status !== "noop") throw new Error(result.reason ?? result.status);
      before.current = next;
      if (result.focus) anchors.current = session.captureTextRange(field, session.resolvePosition(result.focus).offset, session.resolvePosition(result.focus).offset);
      capture();
      if (anchors.current && session.availability("typingShortcut").available) {
        const shortcut = props.execute({ command: "typingShortcut", target: anchors.current, arguments: {} });
        if (shortcut.status === "applied" && shortcut.focus) { anchors.current = session.captureTextRange(shortcut.focus.field, 0, 0); before.current = session.text(shortcut.focus.field); }
      }
      if (anchors.current) props.query(field, next, anchors.current, root);
    } catch (error) {
      pending.current = true; if (target) props.host?.retainInput({ range: target }, replacement, String(error));
      else if (original.current) props.host?.retainInput({ range: original.current }, next, `Original buffer retained; explicit plain-text recovery required: ${error}`);
      props.report(error);
    }
  }
  useLayoutEffect(() => {
    if (!element.current || composing.current || pending.current) return;
    const signature = key(props.value);
    if (rendered.current !== signature) { renderInline(element.current, props.value, props.openReference); rendered.current = signature; }
    before.current = value;
    original.current = session.captureTextRange(field, 0, value.length);
    if (document.activeElement === element.current && anchors.current) {
      try {
        const a = session.resolvePosition(anchors.current.start).offset, b = session.resolvePosition(anchors.current.end).offset;
        selectInline(element.current, Math.min(a, b), Math.max(a, b), a > b);
      } catch (error) { props.report(error); }
    }
  }, [value, key(props.value), fieldKey]);
  useEffect(() => () => { props.register(field, null); if (composing.current) session.setComposing(false); release.current?.(); }, [session, fieldKey]);
  return <div ref={node => { element.current = node; props.register(field, node); }} className={`modern-input ${field.name === "code" ? "modern-code-input" : ""}`}
    role="textbox" aria-label={props.label} aria-multiline={field.name !== "title"} contentEditable={!props.readOnly} suppressContentEditableWarning
    onFocus={capture} onSelect={capture} onKeyUp={capture} onMouseUp={capture}
    onBlur={() => { session.endTypingGroup(); }} onInput={() => { if (!composing.current) commit(); }}
    onCompositionStart={() => { before.current = session.text(field); release.current = session.holdRemoteChanges(); composing.current = true; session.setComposing(true); }}
    onCompositionEnd={() => { composing.current = false; session.setComposing(false); commit(); const finish = release.current; release.current = undefined; finish?.(); }}
    onPaste={event => { if (!props.host) return; event.preventDefault(); try { const range = selection(); if (range) props.host.paste({ range }, event.clipboardData, field.name === "code" || field.name === "title"); } catch (error) { props.report(error); } }}
    onCopy={event => { if (!props.host) return; event.preventDefault(); const range = selection(); if (range) void props.host.copy({ ranges: [range] }).catch(props.report); }}
    onCut={event => { if (!props.host || props.readOnly) return; event.preventDefault(); const range = selection(); if (range) void props.host.copy({ ranges: [range] }, true).catch(props.report); }}
    onKeyDown={event => {
      if (event.nativeEvent.isComposing || composing.current || props.readOnly) return;
      const range = selection(); if (!range) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") { event.preventDefault(); props.execute({ command: event.shiftKey ? "redo" : "undo", arguments: {} }); return; }
      if (props.navigate?.(event, range)) { event.preventDefault(); return; }
      if (field.name === "code" && (event.key === "Tab" || event.key === "Enter")) { event.preventDefault(); props.execute({ command: "replaceText", target: range, arguments: { text: event.key === "Tab" ? "\t" : "\n" } }); return; }
      if (event.key === "Enter" && props.enter) { event.preventDefault(); if (event.shiftKey && field.name !== "title") props.execute({ command: "softBreak", target: range, arguments: {} }); else props.enter(range); }
    }} />;
}

function domPoint(root: HTMLElement, at: number): { node: Node; offset: number } {
  const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT); let remaining = at, last: Node | undefined;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) { const size = node.textContent?.length ?? 0; if (remaining <= size) return { node, offset: remaining }; remaining -= size; last = node; }
  return last ? { node: last, offset: last.textContent?.length ?? 0 } : { node: root, offset: 0 };
}
function ModernEmptyInput({ session, host, readOnly, execute, report }: Pick<InputProps, "session" | "host" | "readOnly" | "execute" | "report">) {
  const root = useRef<HTMLDivElement>(null), composing = useRef(false), release = useRef<(() => void) | undefined>(undefined);
  const boundary = useRef(session.captureBoundary()), id = useRef(crypto.randomUUID());
  function commit(): void {
    const value = root.current?.textContent ?? "";
    if (value) host?.retainInput({ boundary: boundary.current }, value, composing.current ? "compositionActive" : "awaitingCommit", id.current);
    if (composing.current) return;
    if (!value) { if (host) host.inputs = host.inputs.filter(item => item.id !== id.current); return; }
    try {
      const result = execute({ command: "paste", target: { boundary: boundary.current }, arguments: { clipboard: session.clipboard(value, "multiline") } });
      if (result.status === "applied" || result.status === "noop") { if (host) host.inputs = host.inputs.filter(item => item.id !== id.current); }
    } catch (failure) { report(failure); }
  }
  useEffect(() => () => { if (composing.current) session.setComposing(false); release.current?.(); }, [session]);
  return <div ref={root} contentEditable={!readOnly} role="textbox" aria-label="Start writing" suppressContentEditableWarning data-placeholder="Start writing…"
    onInput={commit} onCompositionStart={() => { release.current = session.holdRemoteChanges(); composing.current = true; session.setComposing(true); }}
    onCompositionEnd={() => { composing.current = false; session.setComposing(false); commit(); const finish = release.current; release.current = undefined; finish?.(); }} />;
}

export type ModernMediaPresentation = { readonly status: "available"; readonly url: string; readonly dispose?: () => void } | { readonly status: "denied" | "offline" | "unavailable"; readonly reason?: string };
function ModernMediaView({ session, host, node, value, width, readOnly, resolve, replace, execute, open, report }: {
  session: SwiftModernSession; host?: ModernBrowserHost; node: ModernNodeID; value: ModernObject; width: number; readOnly: boolean;
  resolve?: SwiftModernEditorProps["resolveMedia"]; replace?: SwiftModernEditorProps["requestMediaReplacement"]; execute: InputProps["execute"];
  open?: SwiftModernEditorProps["onOpenReference"]; report: InputProps["report"];
}) {
  const [presentation, setPresentation] = useState<ModernMediaPresentation>(), [failure, setFailure] = useState<string>(), [retry, setRetry] = useState(0);
  const [preview, setPreview] = useState<number>(), target = useRef<ReturnType<SwiftModernSession["captureMediaTarget"]> | undefined>(undefined);
  const source = text(value.src ?? value.url), kind = text(value.type), originalWidth = Number(value.width ?? width), originalHeight = Number(value.height ?? originalWidth);
  useEffect(() => {
    const controller = new AbortController(); let disposed: (() => void) | undefined;
    setPresentation(undefined); setFailure(undefined);
    if (!resolve) { setPresentation({ status: "unavailable", reason: "The application has not supplied media resolution" }); return; }
    resolve(node, value, controller.signal).then(result => {
      if (controller.signal.aborted) { if (result.status === "available") result.dispose?.(); return; }
      disposed = result.status === "available" ? result.dispose : undefined; setPresentation(result);
    }).catch(error => { if (!controller.signal.aborted) setFailure(String(error)); });
    return () => { controller.abort(); disposed?.(); };
  }, [resolve, source, key(node), retry]);
  function commitResize(): void {
    if (preview === undefined || !target.current) return;
    try { const result = execute({ command: "mediaProperties", target: target.current, arguments: { metadata: { width: Math.round(preview), height: Math.max(1, Math.round(originalHeight * preview / Math.max(1, originalWidth))) } } });
      if (result.status !== "applied" && result.status !== "noop") throw new Error(result.reason ?? result.status);
      setPreview(undefined); target.current = undefined;
    } catch (error) { setFailure(String(error)); report(error); }
  }
  const request = session.asyncRequests().find(item => key(item.target.origin.node) === key(node) && item.status !== "applied");
  return <div className="modern-media">
    {presentation?.status === "available" && kind === "image" ? <img src={presentation.url} alt={text(value.alt)} style={{ maxWidth: "100%", width: preview ?? (typeof value.width === "number" ? value.width : undefined), height: "auto" }} onError={() => setFailure("Image could not be displayed")} /> : <p role="status">{failure ?? (presentation ? presentation.status === "available" ? text(value.name ?? value.title ?? value.url) : presentation.reason ?? presentation.status : "Loading media…")}</p>}
    {kind !== "image" && <button disabled={!open} onClick={() => open?.(source, kind)}>{text(value.name ?? value.title ?? value.url) || "Open attachment"}</button>}
    {(failure || presentation?.status === "offline" || presentation?.status === "unavailable") && resolve && <button onClick={() => setRetry(value => value + 1)}>Retry media resolution</button>}
    {request && <p role="status">{request.status === "pending" ? "Uploading or resolving…" : request.reason ?? request.status}</p>}
    {replace && host && <button disabled={readOnly || !!session.capabilities().isComposing} onClick={() => void host.runProvider(node, target => replace(target, value)).catch(report)}>Replace or resolve {kind}</button>}
    {kind === "image" && <label>Image width<input type="range" aria-label="Image width" min={64} max={Math.max(64, width)} value={Math.min(Math.max(64, preview ?? originalWidth), Math.max(64, width))} disabled={readOnly || !!session.capabilities().isComposing}
      onPointerDown={() => { target.current = session.captureMediaTarget(node); }} onChange={event => { target.current ??= session.captureMediaTarget(node); setPreview(Number(event.target.value)); }} onPointerUp={commitResize} onKeyUp={commitResize}
      onPointerCancel={() => { setPreview(undefined); target.current = undefined; }} /></label>}
  </div>;
}

export interface ModernLinkSuggestion { readonly id: string; readonly type: string; readonly label: string; readonly availability: "available" | "denied" | "unavailable" }
export interface SwiftModernEditorProps {
  readonly session: SwiftModernSession; readonly host?: ModernBrowserHost; readonly readOnly?: boolean;
  readonly onError?: (error: unknown) => void; readonly onOpenReference?: (id: string, type: string) => void;
  readonly onCopyBlockLink?: (node: ModernNodeID) => void;
  readonly onInsertAsset?: (descriptor: ModernInsertionDescriptor, boundary: ModernBoundary, range?: ModernTextRange) => void;
  readonly resolveMedia?: (node: ModernNodeID, value: ModernObject, signal: AbortSignal) => Promise<ModernMediaPresentation>;
  readonly requestMediaReplacement?: (target: Parameters<ModernBrowserHost["retryResult"]>[0], value: ModernObject) => Promise<ModernObject>;
  readonly suggestLinks?: (query: string, signal: AbortSignal) => Promise<readonly ModernLinkSuggestion[]>;
}

export function SwiftModernBlockEditor(props: SwiftModernEditorProps) {
  const { session } = props, snapshot = useSyncExternalStore(session.subscribe, session.getSnapshot, session.getSnapshot);
  const [error, setError] = useState<string>(), [focusMode, setFocusMode] = useState(false), [outline, setOutline] = useState(false);
  const [nodes, setNodes] = useState<ModernNodes>(), [menu, setMenu] = useState<{ boundary: ModernBoundary; range?: ModernTextRange; query: string; index: number; anchor?: DOMRect }>();
  const [link, setLink] = useState<{ range: ModernTextRange; query: string; internal: boolean }>(), [suggestions, setSuggestions] = useState<readonly ModernLinkSuggestion[]>([]);
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set());
  const [split, setSplit] = useState<Record<string, number>>({}), [focused, setFocused] = useState<ModernPosition>();
  const [textSpan, setTextSpan] = useState<readonly ModernTextRange[]>([]), [, redrawSelection] = useState(0);
  const fields = useRef(new Map<string, HTMLElement>()), selected = useRef<ModernTextRange | undefined>(undefined), drag = useRef<ModernNodes | undefined>(undefined), drop = useRef<ModernBoundary | undefined>(undefined);
  const viewport = useRef<HTMLDivElement>(null), [width, setWidth] = useState(680);
  const readOnly = !!props.readOnly || !!snapshot.recovery;
  const report = (failure: unknown) => { setError(String(failure)); props.onError?.(failure); };
  const execute = (command: ModernAuthorCommand): ModernResult => {
    const result = session.execute(command);
    if (result.status === "unavailable" || result.status === "recoveryRequired") report(result.reason ?? result.status);
    else {
      setError(undefined);
      const ordinaryTyping = (command.command === "replaceText" || command.command === "replaceTitle") && !!command.arguments.typingGroup;
      if (command.command === "format" && "ranges" in command.target) {
        setTextSpan(command.target.ranges); restoreSpan(command.target.ranges);
      } else if (result.focus && !ordinaryTyping && !(command.command === "typingShortcut" && result.status === "noop")) { setTextSpan([]); setFocused(result.focus); }
    }
    return result;
  };
  const safe = (action: () => void) => { try { action(); } catch (failure) { report(failure); } };
  useLayoutEffect(() => {
    if (!focused) return;
    const root = fields.current.get(key(focused.field)); if (!root) return;
    try { root.focus({ preventScroll: true }); const offset = session.resolvePosition(focused).offset; selectInline(root, offset); root.scrollIntoView({ block: "nearest" }); setFocused(undefined); } catch (failure) { report(failure); }
  }, [focused, snapshot]);
  useLayoutEffect(() => {
    const root = viewport.current; if (!root) return;
    const observer = new ResizeObserver(entries => setWidth(entries[0]?.contentRect.width ?? 680)); observer.observe(root); return () => observer.disconnect();
  }, []);
  useEffect(() => { if (props.host) props.host.readOnly = readOnly; }, [props.host, readOnly]);
  useEffect(() => {
    if (!link?.internal || !props.suggestLinks) { setSuggestions([]); return; }
    const controller = new AbortController();
    props.suggestLinks(link.query, controller.signal).then(value => { if (!controller.signal.aborted) setSuggestions(value); }).catch(failure => { if (!controller.signal.aborted) report(failure); });
    return () => controller.abort();
  }, [link?.query, link?.internal, props.suggestLinks]);
  function restoreSpan(ranges: readonly ModernTextRange[]): void {
    if (ranges.length < 2) return;
    requestAnimationFrame(() => { try {
      const backward = session.resolvePosition(ranges[0].start).offset > session.resolvePosition(ranges[0].end).offset;
      const start = backward ? ranges.at(-1)!.start : ranges[0].start, end = backward ? ranges[0].end : ranges.at(-1)!.end;
      const aRoot = fields.current.get(key(start.field)), bRoot = fields.current.get(key(end.field)); if (!aRoot || !bRoot) return;
      const a = domPoint(aRoot, session.resolvePosition(start).offset), b = domPoint(bRoot, session.resolvePosition(end).offset);
      document.getSelection()?.setBaseAndExtent(a.node, a.offset, b.node, b.offset);
    } catch (failure) { report(failure); } });
  }
  useEffect(() => {
    const changed = () => {
      if (session.capabilities().isComposing) return;
      const selection = document.getSelection(); if (!selection?.anchorNode || !selection.focusNode || !viewport.current?.contains(selection.anchorNode) || !viewport.current.contains(selection.focusNode)) return;
      try {
        const endpoint = (node: Node, offset: number): ModernPosition | undefined => {
          for (const [fieldKey, root] of fields.current) if (root === node || root.contains(node)) {
            const prefix = document.createRange(); prefix.selectNodeContents(root); prefix.setEnd(node, offset);
            return session.position(JSON.parse(fieldKey) as ModernField, prefix.toString().length);
          }
        };
        const start = endpoint(selection.anchorNode, selection.anchorOffset), end = endpoint(selection.focusNode, selection.focusOffset); if (!start || !end) return;
        const ranges = session.captureTextSpan(start, end);
        if (ranges.length > 1) {
          setTextSpan(ranges); selected.current = ranges.at(-1);
          const local = { documentID: start.documentID, epoch: start.epoch, observed: ranges[0].observed, focus: { text: { _0: end } }, selection: { mixed: { _0: { ranges } } } };
          if (key(session.localSelection()) !== key(local)) session.setLocalSelection(local);
        } else { selected.current = ranges[0]; setTextSpan([]); }
        redrawSelection(value => value + 1);
      } catch (failure) { report(failure); }
    };
    document.addEventListener("selectionchange", changed); return () => document.removeEventListener("selectionchange", changed);
  }, [session]);
  function selectedTarget(): { ranges: readonly ModernTextRange[] } { return { ranges: textSpan.length ? textSpan : selected.current ? [selected.current] : [] }; }
  function formattingState(mark: string): "on" | "off" | "mixed" { try { const ranges = selectedTarget().ranges; return ranges.length ? session.markState(ranges, mark) : "off"; } catch { return "off"; } }
  function palette(): ReactNode {
    const target: ModernSemanticTarget | undefined = nodes ? { nodes } : selected.current ? { range: selected.current } : undefined;
    return (["ink", "fill"] as const).map(kind => {
      let current: ReturnType<SwiftModernSession["semanticState"]> | undefined;
      try { if (target) current = session.semanticState(target, kind); } catch { /* Stale captures remain unavailable. */ }
      const state = current && "role" in current ? current.role._0 : current && "mixed" in current ? "mixed" : "reset";
      return <details key={kind}><summary>{kind === "ink" ? "Text color" : "Background"}: {state === "reset" ? "Default" : state}</summary>{["neutral", "green", "blue", "purple", "amber", "red", "reset"].map(role => <button key={role} aria-pressed={state === role} disabled={readOnly || !target} onClick={() => { if (target) execute({ command: "setSemanticColor", target, arguments: { kind, role: role === "reset" ? null : role as "neutral" } }); }}>{role}</button>)}</details>;
    });
  }
  function spanPasteTarget() {
    const backward = session.resolvePosition(textSpan[0].start).offset > session.resolvePosition(textSpan[0].end).offset;
    return { range: { start: backward ? textSpan.at(-1)!.start : textSpan[0].start, end: backward ? textSpan[0].end : textSpan.at(-1)!.end, observed: textSpan[0].observed } };
  }
  const catalog = session.insertionCatalog(menu?.query ?? "");
  function origin(blockID: string, path: readonly string[]): ModernNodeID { return session.node({ blockID, path }); }
  function input(node: ModernNodeID, name: string, value: readonly ModernObject[] | string, label: string, enter = true, navigate?: InputProps["navigate"]): ReactNode {
    const field = session.field(node, name);
    return <ModernInput key={key(field)} session={session} host={props.host} field={field} value={value} label={label} readOnly={readOnly}
      register={(field, element) => { if (element) fields.current.set(key(field), element); else fields.current.delete(key(field)); }}
      selected={range => { selected.current = range; setTextSpan([]); redrawSelection(value => value + 1); }} report={report} execute={execute} navigate={(event, range) => navigate?.(event, range) || boundary(event, range)} openReference={props.onOpenReference}
      query={(field, value, range, element) => {
        if (field.name !== "content") return;
        if (value.startsWith("/") && !value.includes("\n")) {
          safe(() => { setMenu({ boundary: session.captureInsertionBoundary(field), range: session.captureTextRange(field, 0, value.length), query: value.slice(1), index: 0, anchor: element.getBoundingClientRect() }); });
        } else if (props.suggestLinks) {
          const at = value.lastIndexOf("[["); if (at >= 0 && !value.slice(at).includes("]]")) setLink({ range: session.captureTextRange(field, at, value.length), query: value.slice(at + 2), internal: true });
        }
      }} enter={enter ? range => {
        safe(() => {
          if (name === "title") {
            const first = firstEditable(snapshot.document.blocks, []); if (first) { setFocused(session.position(first, 0)); return; }
            execute({ command: "insertBlock", target: session.captureBoundary(), arguments: { block: { id: crypto.randomUUID(), type: "paragraph", content: [] } } });
          } else if (name === "summary") {
            setCollapsed(previous => { const next = new Set(previous); next.delete(key(node)); return next; });
            execute({ command: "insertBlock", target: session.captureBoundary({ owner: node, field: "children" }), arguments: { block: session.insertionValue("paragraph", crypto.randomUUID()) } });
          } else execute({ command: "splitBlock", target: range, arguments: { newBlockID: crypto.randomUUID() } });
        });
      } : undefined} />;
  }
  function find(node: ModernNodeID): { blockID: string; path: string[]; value: ModernObject } | undefined {
    let found: { blockID: string; path: string[]; value: ModernObject } | undefined;
    function visit(values: readonly ModernObject[], blockID?: string, path: string[] = []): void {
      for (const value of values) {
        const root = blockID ?? text(value.id), current = blockID ? [...path, text(value.id)] : [];
        if (key(origin(root, current)) === key(node)) { found = { blockID: root, path: current, value }; return; }
        for (const field of ["columns", "children", "items", "rows", "cells"]) if (Array.isArray(value[field])) visit(array(value[field]), root, [...current, field]);
      }
    }
    visit(snapshot.document.blocks); return found;
  }
  function parent(node: ModernNodeID): ModernCollection { return session.parentCollection(node); }
  function reveal(node: ModernNodeID): void {
    const next = new Set(collapsed); let current = node;
    while (true) { const collection = parent(current); if (!collection.owner) break; next.delete(key(collection.owner)); current = collection.owner; }
    setCollapsed(next); setFocused(session.position(session.field(node), 0));
  }
  function boundary(event: KeyboardEvent<HTMLDivElement>, range: ModernTextRange): boolean {
    const field = range.start.field, start = session.resolvePosition(range.start).offset, end = session.resolvePosition(range.end).offset;
    if (start !== end) return false;
    const backward = ["Backspace", "ArrowLeft", "ArrowUp"].includes(event.key), forward = ["Delete", "ArrowRight", "ArrowDown"].includes(event.key);
    if ((!backward && !forward) || (backward ? start !== 0 : end !== session.text(field).length)) return false;
    if (event.key === "Backspace" || event.key === "Delete") {
      if (field.name !== "content" || "document" in field.node) return false;
      safe(() => {
        const collection = parent(field.node), siblings = session.nodes(collection), index = siblings.findIndex(id => key(id) === key(field.node));
        if ((collection.field === "items" || collection.field === "children") && event.key === "Backspace") {
          const selection = session.captureListNodes([field.node]);
          execute(session.text(field) === "" ? { command: "splitBlock", target: range, arguments: { newBlockID: crypto.randomUUID() } } : { command: "listStructure", target: { selection }, arguments: { action: "outdent" } });
        } else if ((backward && index > 0) || (forward && index + 1 < siblings.length)) {
          execute({ command: "mergeBlocks", target: session.captureNodes(backward ? [siblings[index - 1], field.node] : [field.node, siblings[index + 1]]), arguments: {} });
        }
      }); return true;
    }
    const visibleFields = session.logicalFields().filter(value => fields.current.has(key(value))), index = visibleFields.findIndex(value => key(value) === key(field)), next = visibleFields[index + (backward ? -1 : 1)];
    if (!next) return false;
    if (event.shiftKey && !("document" in field.node) && !("document" in next.node)) {
      safe(() => {
        const ranges = session.captureTextSpan(range.start, session.position(next, backward ? session.text(next).length : 0));
        setTextSpan(ranges); selected.current = ranges.at(-1); restoreSpan(ranges);
        session.setLocalSelection({ documentID: range.start.documentID, epoch: range.start.epoch, observed: ranges[0].observed,
          focus: { text: { _0: backward ? ranges[0].end : ranges.at(-1)!.end } }, selection: { mixed: { _0: { ranges } } } });
      }); return true;
    }
    setFocused(session.position(next, backward ? session.text(next).length : 0)); return true;
  }
  function firstEditable(values: readonly ModernObject[], path: string[], rootID?: string): ModernField | undefined {
    for (const value of values) {
      const root = rootID ?? text(value.id), current = rootID ? [...path, text(value.id)] : [];
      const node = origin(root, current);
      for (const name of ["content", "summary", "code", "caption"]) { if (value[name] !== undefined) return session.field(node, name); }
      for (const child of ["columns", "children", "items", "rows", "cells"]) { const result = firstEditable(array(value[child]), [...current, child], root); if (result) return result; }
    }
  }
  function selectedBlocks(node: ModernNodeID, extend: boolean): void {
    safe(() => {
      const siblings = session.nodes(parent(node));
      if (extend && nodes) { const a = siblings.findIndex(id => key(id) === key(nodes.nodes[0])), b = siblings.findIndex(id => key(id) === key(node)); if (a >= 0 && b >= 0) { setNodes(session.captureNodes(siblings.slice(Math.min(a, b), Math.max(a, b) + 1))); return; } }
      setNodes(session.captureNodes([node]));
    });
  }
  function move(down: boolean): void {
    if (!nodes) return;
    safe(() => {
      const collection = parent(nodes.nodes[0]), siblings = session.nodes(collection), index = siblings.findIndex(node => key(node) === key(nodes.nodes[0]));
      if ((!down && index === 0) || (down && index + nodes.nodes.length === siblings.length)) return;
      const after = down ? siblings[index + nodes.nodes.length] : index > 1 ? siblings[index - 2] : undefined;
      execute({ command: "move", target: { selection: nodes, boundary: session.captureBoundary(collection, after) }, arguments: {} });
      setNodes(session.captureNodes(nodes.nodes));
    });
  }
  function insert(descriptor: ModernInsertionDescriptor): void {
    if (!menu) return;
    safe(() => {
      if (descriptor.requiresHost) { if (!props.onInsertAsset) throw new Error("The application has not supplied asset insertion"); props.onInsertAsset(descriptor, menu.boundary, menu.range); setMenu(undefined); return; }
      const id = () => crypto.randomUUID();
      const count = descriptor.blockType === "list" ? 1 : descriptor.blockType === "table" ? 6 : descriptor.blockType === "columns" ? 2 : 0;
      const block = session.insertionValue(descriptor.id, id(), Array.from({ length: count }, id));
      if (descriptor.blockType === "columns" && !menu.range) {
        execute({ command: "createColumns", target: { boundary: menu.boundary }, arguments: { layout: block as ModernObject } });
      } else if (menu.range) execute({ command: "paste", target: { boundary: menu.boundary, selection: { ranges: [menu.range] } }, arguments: { clipboard: session.clipboardParts([{ node: { kind: "block", value: block as ModernObject } }]), focusInserted: true } });
      else execute({ command: "insertBlock", target: menu.boundary, arguments: { block: block as ModernObject } });
      setMenu(undefined);
    });
  }
  function renderBlocks(values: readonly ModernObject[], collection: ModernCollection, rootID?: string, path: string[] = [], available = width): ReactNode {
    return values.map(value => {
      const root = rootID ?? text(value.id), current = rootID ? [...path, text(value.id)] : [], node = origin(root, current), nodeKey = key(node), type = text(value.type);
      let content: ReactNode;
      if (type === "columns") {
        const containers = array(value.columns), usable = available - 24, minimum = (viewport.current ? Number.parseFloat(getComputedStyle(viewport.current).fontSize) : snapshot.document.appearance.fontSize === "large" ? 20 : snapshot.document.appearance.fontSize === "small" ? 15 : 17) * 20;
        const stored = Number(value.splitBasisPoints ?? 5000), preview = split[nodeKey] ?? stored, ratio = Math.max(minimum / Math.max(1, usable), Math.min(1 - minimum / Math.max(1, usable), preview / 10000));
        content = containers.length !== 2 ? <p role="status">Incompatible columns preserved</p> : <>
          <div className="modern-columns" style={{ display: "grid", gap: 24, gridTemplateColumns: usable < 2 * minimum ? "1fr" : `${ratio}fr ${1 - ratio}fr` }}>
            {containers.map((container, index) => { const columnNode = origin(root, [...current, "columns", text(container.id)]), children: ModernCollection = { owner: columnNode, field: "children" }; return <div key={text(container.id)}>{renderBlocks(array(container.children), children, root, [...current, "columns", text(container.id), "children"], usable < 2 * minimum ? available : usable * (index === 0 ? ratio : 1 - ratio))}<button disabled={readOnly} onClick={() => setMenu({ boundary: session.captureBoundary(children, session.nodes(children).at(-1)), query: "", index: 0 })}>Add to column {index + 1}</button></div>; })}
          </div>
          <input aria-label="Column split" type="range" min={1000} max={9000} value={preview} disabled={readOnly} onChange={event => setSplit({ ...split, [nodeKey]: Number(event.target.value) })}
            onPointerUp={() => { execute({ command: "resizeColumns", target: { layout: node }, arguments: { splitBasisPoints: preview } }); setSplit(previous => { const next = { ...previous }; delete next[nodeKey]; return next; }); }}
            onKeyUp={() => { execute({ command: "resizeColumns", target: { layout: node }, arguments: { splitBasisPoints: preview } }); }} />
          <button disabled={readOnly} onClick={() => execute({ command: "removeColumns", target: { layout: node }, arguments: {} })}>Remove columns</button>
        </>;
      } else if (type === "list") {
        function item(item: ModernObject, itemPath: string[], index: number): ReactNode {
          const itemNode = origin(root, [...itemPath, text(item.id)]), style = text(value.style);
          return <li key={text(item.id)}>{style === "todo" && <input type="checkbox" aria-label="Completed" checked={!!item.checked} disabled={readOnly} onChange={event => execute({ command: "listStructure", target: { selection: session.captureListNodes([itemNode]) }, arguments: { action: "setChecked", checked: event.target.checked } })} />}
            {input(itemNode, "content", array(item.content), "List item", true, (event, range) => { if (event.key !== "Tab") return false; execute({ command: "listStructure", target: { selection: session.captureListNodes([itemNode]), caret: range.end }, arguments: { action: event.shiftKey ? "outdent" : "indent" } }); return true; })}
            {!!array(item.children).length && <ul>{array(item.children).map((child, i) => itemView(child, [...itemPath, text(item.id), "children"], i))}</ul>}
          </li>;
        }
        const itemView = item;
        content = !array(value.items).length ? <button disabled={readOnly} onClick={() => safe(() => execute({ command: "paste", target: { boundary: session.captureListBoundary({ owner: node, field: "items" }) }, arguments: { clipboard: session.clipboardParts([{ node: { kind: "item", value: { id: crypto.randomUUID(), content: [], checked: false } } }]) } }))}>Add list item</button> : value.style === "ordered" ? <ol>{array(value.items).map((value, i) => item(value, [...current, "items"], i))}</ol> : <ul className={value.style === "todo" ? "modern-checklist" : ""}>{array(value.items).map((value, i) => item(value, [...current, "items"], i))}</ul>;
      } else if (type === "table") {
        const tableRows = array(value.rows), cellFields = tableRows.flatMap(row => array(row.cells).map(cell => session.field(origin(root, [...current, "rows", text(row.id), "cells", text(cell.id)]))));
        content = <div className="modern-table-scroll"><table><tbody>{tableRows.map(row => <tr key={text(row.id)}>{array(row.cells).map(cell => {
          const rowNode = origin(root, [...current, "rows", text(row.id)]), cellNode = origin(root, [...current, "rows", text(row.id), "cells", text(cell.id)]), capturedCell = session.captureTableTarget(node, rowNode, cellNode), Tag = cell.header ? "th" : "td";
          return <Tag key={text(cell.id)} scope={cell.header ? "col" : undefined}>
            {input(cellNode, "content", array(cell.content), cell.header ? "Table header" : "Table cell", false, (event, range) => {
              if (event.key !== "Tab" && event.key !== "Enter") return false;
              const index = cellFields.findIndex(field => key(field) === key(range.start.field)), next = cellFields[index + (event.shiftKey ? -1 : 1)];
              if (next) setFocused(session.position(next, 0)); return !!next;
            })}
            <details><summary aria-label="Cell actions">⋯</summary>{["insertRow", "removeRow", "insertColumn", "removeColumn", "setHeader"].map(action => <button key={action} disabled={readOnly} onClick={() => execute({ command: "tableStructure", target: capturedCell, arguments: { action: action as "insertRow", newIDs: Array.from({ length: action === "insertRow" ? array(row.cells).length + 1 : action === "insertColumn" ? tableRows.length : 0 }, () => crypto.randomUUID()), ...(action === "setHeader" ? { header: !cell.header } : {}) } })}>{action.replace(/([A-Z])/g, " $1")}</button>)}</details>
          </Tag>;
        })}</tr>)}</tbody></table></div>;
      } else if (type === "toggle") content = <div><button aria-expanded={!collapsed.has(nodeKey)} onClick={() => {
        if (!collapsed.has(nodeKey)) setFocused(session.position(session.field(node, "summary"), 0));
        setCollapsed(previous => { const next = new Set(previous); if (next.has(nodeKey)) next.delete(nodeKey); else next.add(nodeKey); return next; });
      }}>{collapsed.has(nodeKey) ? "▸" : "▾"}</button>{input(node, "summary", array(value.summary), "Toggle title")}
        {!collapsed.has(nodeKey) && <div className="modern-nested">{renderBlocks(array(value.children), { owner: node, field: "children" }, root, [...current, "children"], available - 24)}<button onClick={() => setMenu({ boundary: session.captureBoundary({ owner: node, field: "children" }, session.nodes({ owner: node, field: "children" }).at(-1)), query: "", index: 0 })}>Add inside toggle</button></div>}</div>;
      else if (type === "code") content = <div className="modern-code"><div><label>Language<select aria-label="Code language" disabled={readOnly} value={text(value.language)} onChange={event => execute({ command: "codeProperties", target: session.captureCodeTarget(node), arguments: { language: event.target.value || null } })}><option value="">Plain text</option>{session.capabilities().codeLanguages.map(language => <option key={language}>{language}</option>)}</select></label><button onClick={() => navigator.clipboard.writeText(text(value.code)).catch(report)}>Copy code</button></div>{input(node, "code", text(value.code), "Code", false)}</div>;
      else if (type === "image" || type === "file" || type === "embed") content = <figure>
        <ModernMediaView session={session} host={props.host} node={node} value={value} width={available} readOnly={readOnly} resolve={props.resolveMedia} replace={props.requestMediaReplacement} execute={execute} open={props.onOpenReference} report={report} />
        {type === "image" && input(node, "caption", array(value.caption), "Image caption", false)}
      </figure>;
      else if (type === "divider") content = <hr />;
      else if (["paragraph", "heading", "quote", "callout"].includes(type)) content = input(node, "content", array(value.content), type === "heading" ? "Heading" : "Block text");
      else content = <p role="status">Unsupported content preserved</p>;
      return <div key={nodeKey} id={`modern-${encodeURIComponent(nodeKey)}`} data-block-type={type} data-level={value.level} data-ink={value.semanticColor} data-fill={value.semanticBackground}
        className={`modern-block ${nodes?.nodes.some(id => key(id) === nodeKey) ? "modern-selected" : ""}`}
        onDragStart={event => { event.stopPropagation(); drag.current = session.captureNodes(nodes?.nodes.some(id => key(id) === nodeKey) ? nodes.nodes : [node]); event.dataTransfer.setData("text/plain", "modern-local-move"); }}
        onDragOver={event => { if (!drag.current) return; event.preventDefault(); event.stopPropagation(); const bounds = event.currentTarget.getBoundingClientRect(), before = event.clientY < bounds.top + bounds.height / 2;
          safe(() => { const siblings = session.nodes(collection), index = siblings.findIndex(value => key(value) === nodeKey); drop.current = session.captureBoundary(collection, before ? siblings[index - 1] : node); });
          event.currentTarget.dataset.drop = before ? "before" : "after"; const top = viewport.current?.getBoundingClientRect().top ?? 0; if (event.clientY < top + 48) viewport.current?.scrollBy(0, -16); else if (event.clientY > (viewport.current?.getBoundingClientRect().bottom ?? 0) - 48) viewport.current?.scrollBy(0, 16); }}
        onDragLeave={event => { delete event.currentTarget.dataset.drop; }} onDragEnd={() => { drag.current = undefined; drop.current = undefined; viewport.current?.querySelectorAll("[data-drop]").forEach(element => element.removeAttribute("data-drop")); }}
        onDrop={event => { if (!drag.current || !drop.current) return; event.preventDefault(); event.stopPropagation(); const selection = drag.current, boundary = drop.current; drag.current = undefined; drop.current = undefined; delete event.currentTarget.dataset.drop; safe(() => execute({ command: "move", target: { selection, boundary }, arguments: {} })); }}>
        <button className="modern-handle" draggable={!readOnly} aria-label="Select block" onClick={event => selectedBlocks(node, event.shiftKey)}>⋮⋮</button>{content}
      </div>;
    });
  }
  const appearance = snapshot.document.appearance, bodySize = appearance.fontSize === "small" ? 15 : appearance.fontSize === "large" ? 20 : 17;
  const documentNode: ModernNodeID = { document: { documentID: snapshot.document.documentID } };
  return <section onCopyCapture={event => { if (textSpan.length > 1 && props.host) { event.preventDefault(); event.stopPropagation(); void props.host.copy(selectedTarget()).catch(report); } }}
    onCutCapture={event => { if (textSpan.length > 1 && props.host && !readOnly) { event.preventDefault(); event.stopPropagation(); void props.host.copy(selectedTarget(), true).catch(report); } }}
    onPasteCapture={event => { if (textSpan.length > 1 && props.host && !readOnly) { event.preventDefault(); event.stopPropagation(); safe(() => props.host!.paste(spanPasteTarget(), event.clipboardData)); } }}
    onKeyDownCapture={event => { if (textSpan.length < 2 || readOnly || event.nativeEvent.isComposing) return;
      if (event.key === "Backspace" || event.key === "Delete") { event.preventDefault(); event.stopPropagation(); safe(() => execute({ command: "delete", target: selectedTarget(), arguments: {} })); setTextSpan([]); }
      else if (event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) { event.preventDefault(); event.stopPropagation(); safe(() => execute({ command: "paste", target: spanPasteTarget(), arguments: { clipboard: session.clipboard(event.key) } })); setTextSpan([]); }
    }} className="modern-editor" data-font={appearance.fontFamily} style={{ "--modern-body-size": `${bodySize}px`, "--modern-page-width": appearance.pageWidth === "wide" ? "960px" : "680px" } as CSSProperties}>
    {!focusMode && <div className="modern-topbar"><button onClick={() => setOutline(!outline)} aria-expanded={outline}>Outline</button><button onClick={() => setFocusMode(true)}>Focus</button><details><summary>Appearance</summary>{(["fontFamily", "fontSize", "pageWidth"] as const).map(field => <label key={field}>{field}<select value={appearance[field]} disabled={readOnly} onChange={event => execute({ command: "setAppearance", target: documentNode, arguments: { field, value: event.target.value } } as ModernAuthorCommand)}>{(field === "fontFamily" ? ["sans", "serif", "monospace"] : field === "fontSize" ? ["small", "default", "large"] : ["readable", "wide"]).map(value => <option key={value}>{value}</option>)}</select></label>)}</details></div>}
    {outline && !focusMode && <nav aria-label="Heading outline">{(() => { const items: ReactNode[] = []; function walk(values: readonly ModernObject[], root?: string, path: string[] = []) { values.forEach(value => { const id = root ?? text(value.id), current = root ? [...path, text(value.id)] : []; const node = origin(id, current); if (value.type === "heading") items.push(<button key={key(node)} onClick={() => reveal(node)}>{visible(array(value.content)) || "Heading"}</button>); for (const field of ["columns", "children"]) walk(array(value[field]), id, [...current, field]); }); } walk(snapshot.document.blocks); return items; })()}</nav>}
    <div className="modern-viewport" ref={viewport}><div className="modern-page"><div className="modern-title">{input(documentNode, "title", snapshot.document.title, "Document title")}</div>
      {!snapshot.document.blocks.length && <ModernEmptyInput session={session} host={props.host} readOnly={readOnly} execute={execute} report={report} />}
      {renderBlocks(snapshot.document.blocks, { field: "blocks" })}
      {snapshot.recovery && <div role="alert">Editing is paused for document recovery. Accepted content and pending input are retained.</div>}
      {props.host?.inputs.map(draft => <div role="alert" key={draft.id}>Input retained: {draft.reason}<pre>{draft.text}</pre><button disabled={readOnly} onClick={() => safe(() => props.host?.retryInput(draft.id))}>Retry plain-text input</button></div>)}
      {props.host?.clipboard.map(item => <div role="alert" key={item.id}>Clipboard retained: {item.reason}<button disabled={readOnly} onClick={() => safe(() => props.host?.retryPaste(item.id))}>Retry original paste</button><button disabled={readOnly} onClick={() => safe(() => props.host?.retryPaste(item.id, true))}>Paste plain text</button></div>)}
      {session.asyncRequests().filter(record => record.status !== "applied").map(record => <div role="status" key={record.target.requestID}>{record.reason ?? record.status}{record.result ? <button disabled={readOnly || !props.host} onClick={() => void props.host?.retryResult(record.target).catch(report)}>Retry retained result</button> : record.status === "pending" ? <button disabled={readOnly || !props.host} onClick={() => void props.host?.cancelProvider(record.target).catch(report)}>Cancel request</button> : null}</div>)}
      {error && <div role="alert">{error}</div>}
    </div></div>
    <div className="modern-accessory" role="toolbar" aria-label="Editing actions" onPointerDown={event => { if (event.target instanceof HTMLButtonElement) event.preventDefault(); }}>
      {nodes ? <><span>{nodes.nodes.length} selected</span><details><summary>Convert</summary>{["paragraph", "heading", "quote", "callout", "list", "code"].map(type => <button key={type} disabled={readOnly} onClick={() => execute({ command: "convertBlock", target: nodes, arguments: { type: type as "paragraph" } })}>{type}</button>)}</details>
        <details><summary>Move to</summary>{[{ label: "Document end", collection: { field: "blocks" } as ModernCollection }, ...snapshot.document.blocks.filter(value => value.type === "columns").flatMap(value => array(value.columns).map((column, index) => ({ label: `Column ${index + 1}`, collection: { owner: origin(text(value.id), ["columns", text(column.id)]), field: "children" } as ModernCollection })))].map((destination, index) => <button key={index} disabled={readOnly} onClick={() => safe(() => execute({ command: "move", target: { selection: nodes, boundary: session.captureBoundary(destination.collection, session.nodes(destination.collection).at(-1)) }, arguments: {} }))}>{destination.label}</button>)}</details>
        <button disabled={readOnly} onClick={() => move(false)}>Move up</button><button disabled={readOnly} onClick={() => move(true)}>Move down</button><button disabled={readOnly} onClick={() => safe(() => execute({ command: "duplicate", target: { selection: nodes, boundary: session.captureBoundary(parent(nodes.nodes.at(-1)!), nodes.nodes.at(-1)) }, arguments: { newBlockIDs: nodes.nodes.map(() => crypto.randomUUID()) } }))}>Duplicate</button><button disabled={readOnly} onClick={() => { execute({ command: "delete", target: { nodes, ranges: [] }, arguments: {} }); setNodes(undefined); }}>Delete</button><details><summary>Color</summary>{palette()}</details><button onClick={() => props.onCopyBlockLink?.(nodes.nodes[0])} disabled={!props.onCopyBlockLink}>Copy link</button><button onClick={() => { setNodes(undefined); if (selected.current) setFocused(selected.current.end); }}>Cancel selection</button></> : <>
        <button disabled={readOnly} onClick={() => safe(() => { setMenu({ boundary: selected.current ? session.captureInsertionBoundary(selected.current.start.field) : session.captureBoundary({ field: "blocks" }, session.nodes().at(-1)), query: "", index: 0 }); })}>Insert</button>
        <details className="modern-format-menu"><summary>Format</summary><div>{["bold", "italic", "strikethrough", "code"].map(mark => <button key={mark} aria-pressed={formattingState(mark) === "mixed" ? "mixed" : formattingState(mark) === "on"} disabled={readOnly || !selected.current} onClick={() => { if (selected.current) execute({ command: "format", target: textSpan.length ? { ranges: textSpan } : selected.current, arguments: { markType: mark, mark: formattingState(mark) === "on" ? null : { type: mark } } }); }}>{mark}</button>)}</div></details>
        <button disabled={readOnly || !selected.current} onClick={() => { if (selected.current) setLink({ range: selected.current, query: "", internal: false }); }}>Link</button>
        <button disabled={readOnly || !snapshot.canUndo} onClick={() => execute({ command: "undo", arguments: {} })}>Undo</button>
        <details><summary>More</summary><button disabled={readOnly || !snapshot.canRedo} onClick={() => execute({ command: "redo", arguments: {} })}>Redo</button><button onClick={() => { if (selected.current) selectedBlocks(selected.current.start.field.node, false); }}>Select block</button>{palette()}</details>
      </>}{focusMode && <button onClick={() => setFocusMode(false)}>Leave focus mode</button>}
    </div>
    {menu && <div className="modern-picker" role="dialog" aria-label="Insert block" style={{ left: menu.anchor ? Math.max(8, Math.min(window.innerWidth - 300, menu.anchor.left)) : 16, top: menu.anchor ? Math.max(8, Math.min(window.innerHeight - 440, menu.anchor.bottom)) : 64 }}>
      <input aria-label="Search blocks" autoFocus value={menu.query} onChange={event => setMenu({ ...menu, query: event.target.value, index: 0 })} onKeyDown={event => { if (event.key === "Escape") { setMenu(undefined); if (menu.range) setFocused(menu.range.end); } if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); setMenu({ ...menu, index: Math.max(0, Math.min(catalog.length - 1, menu.index + (event.key === "ArrowDown" ? 1 : -1))) }); } if (event.key === "Enter" && catalog[menu.index]) insert(catalog[menu.index]); }} />
      <div role="listbox">{catalog.map((descriptor, index) => <button role="option" aria-selected={menu.index === index} key={descriptor.id} onClick={() => insert(descriptor)}><strong>{descriptor.title}</strong><small>{descriptor.description}</small></button>)}</div><button onClick={() => { setMenu(undefined); if (menu.range) setFocused(menu.range.end); }}>Cancel</button>
    </div>}
    {link && <div className="modern-picker" role="dialog" aria-label="Link"><input autoFocus aria-label={link.internal ? "Search internal links" : "Link URL"} value={link.query} onChange={event => setLink({ ...link, query: event.target.value })} />
      {link.internal ? suggestions.map(suggestion => <button key={suggestion.id} disabled={suggestion.availability !== "available"} onClick={() => { execute({ command: "paste", target: { range: link.range }, arguments: { clipboard: session.clipboardParts([{ inline: { _0: [{ type: "entity-ref", entityId: suggestion.id, entityType: suggestion.type, label: suggestion.label }] } }]) } }); setLink(undefined); }}>{suggestion.label} {suggestion.availability === "available" ? "" : suggestion.availability}</button>) : <><button onClick={() => { execute({ command: "setLink", target: link.range, arguments: { href: link.query } }); setLink(undefined); }}>Apply link</button><button onClick={() => { execute({ command: "setLink", target: link.range, arguments: { href: null } }); setLink(undefined); }}>Remove link</button><button disabled={!props.suggestLinks} onClick={() => setLink({ ...link, internal: true })}>Find internal link</button></>}
      <button onClick={() => { setLink(undefined); setFocused(link.range.end); }}>Cancel</button>
    </div>}
  </section>;
}

/** The host provides WASM bytes. Loading/incompatibility never substitutes an
 * empty document, and a retry reconstructs only from the original input. */
export function SwiftModernEditorSurface({ source, document, actorID, epoch, policy, ...props }: Omit<SwiftModernEditorProps, "session" | "host"> & { readonly source: () => Promise<BufferSource | WebAssembly.Module>; readonly document: ModernDocument; readonly actorID: string; readonly epoch: string; readonly policy?: ModernPolicy }) {
  const [session, setSession] = useState<SwiftModernSession>(), [error, setError] = useState<string>(), [retry, setRetry] = useState(0);
  useEffect(() => { let active = true, created: SwiftModernSession | undefined; setError(undefined); setSession(undefined);
    source().then(bytes => SwiftEditorRuntime.initialize(bytes)).then(runtime => { if (!active) return; created = runtime.createModern({ documentID: document.documentID, actorID, epoch, document, ...policy }); setSession(created); }).catch(error => { if (active) setError(String(error)); });
    return () => { active = false; created?.close(); };
  }, [source, document, actorID, epoch, policy, retry]);
  if (error) return <div role="alert">The editor could not load this document. {error}<button onClick={() => setRetry(retry + 1)}>Retry</button></div>;
  if (!session) return <div role="status">Loading editor…</div>;
  return <SwiftModernBlockEditor {...props} session={session} />;
}
