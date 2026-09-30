import { useEffect, useState, useSyncExternalStore, type ReactNode } from "react";
import { InlineEditor } from "./inline-react.js";
import type { Block, InlineNode } from "./schema.js";
import { SwiftEditorRuntime, type SwiftEditorSession, type SwiftChangeBatch, type TextAddress } from "./swift.js";

export interface SwiftBlockEditorProps {
  /** Keep this function stable; changing it intentionally replaces the editing session. */
  loadModule: () => Promise<BufferSource | WebAssembly.Module>;
  documentID: string;
  actorID: string;
  initialBlocks: Block[];
  initialSnapshot?: SwiftChangeBatch;
  onReady?: (session: SwiftEditorSession) => void | (() => void);
  onChange?: (blocks: Block[]) => void;
  renderImage?: (block: Extract<Block, { type: "image" }>) => ReactNode;
}

/** Swift-powered integration surface. The existing full React editor remains available
 * while native input, authoring and visual parity are completed. */
export function SwiftBlockEditor({ loadModule, documentID, actorID, initialBlocks, initialSnapshot, onReady, ...props }: SwiftBlockEditorProps) {
  const [session, setSession] = useState<SwiftEditorSession | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    let canceled = false;
    let current: SwiftEditorSession | undefined;
    let disconnect: void | (() => void);
    setSession(null); setError(null);
    void loadModule().then(source => SwiftEditorRuntime.initialize(source)).then(runtime => {
      if (canceled) return;
      current = initialSnapshot ? runtime.restore(initialSnapshot, actorID) : runtime.create({ documentID, actorID, blocks: initialBlocks });
      disconnect = onReady?.(current);
      setSession(current);
    }).catch(reason => { if (!canceled) setError(String(reason)); });
    return () => { canceled = true; disconnect?.(); current?.close(); };
    // Initial content is captured when document/actor/loader identity changes. Subsequent
    // updates use the session API, so host re-renders do not overwrite collaborative state.
  }, [loadModule, documentID, actorID, retry]);
  if (error) return <div role="alert">Unable to open the editor. <button onClick={() => setRetry(value => value + 1)}>Retry</button><details><summary>Details</summary>{error}</details></div>;
  if (!session) return <div role="status">Loading editor…</div>;
  return <SwiftEditorSurface session={session} {...props} />;
}

export function SwiftEditorSurface({ session, onChange, renderImage }: {
  session: SwiftEditorSession;
  onChange?: (blocks: Block[]) => void;
  renderImage?: SwiftBlockEditorProps["renderImage"];
}) {
  const snapshot = useSyncExternalStore(session.subscribe, session.getSnapshot, session.getSnapshot);
  const [focused, setFocused] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { onChange?.(snapshot.blocks); }, [snapshot, onChange]);
  function perform(action: () => void) { try { action(); setError(null); } catch (error) { setError(String(error)); } }
  function insert(after?: string) { session.insert({ id: crypto.randomUUID(), type: "paragraph", content: [] }, after); }
  function inline(address: TextAddress, nodes: InlineNode[]) {
    const key = JSON.stringify(address);
    return <InlineEditor content={nodes} placeholder="Write something…" autoFocus={false}
      focused={focused === key} inputRef={() => {}} onFocus={() => setFocused(key)} onKeyDown={() => {}}
      onPaste={event => {
        // Browser HTML access stays in the adapter. The current surface deliberately
        // uses plain paste until structured multi-block paste parity is verified.
        event.preventDefault();
        const selection = event.currentTarget.ownerDocument.getSelection();
        if (!selection?.rangeCount) return;
        const range = selection.getRangeAt(0), prefix = range.cloneRange();
        prefix.selectNodeContents(event.currentTarget); prefix.setEnd(range.startContainer, range.startOffset);
        const start = prefix.toString().length;
        perform(() => session.replaceText(address, start, start + range.toString().length, event.clipboardData.getData("text/plain")));
      }}
      onChange={nodes => perform(() => session.setInline(address, nodes))}
      onEnter={() => perform(() => insert(address.blockID))}
      onHistory={direction => perform(() => direction === "undo" ? session.undo() : session.redo())} />;
  }
  function render(block: Block, rootID = block.id, path: string[] = []): ReactNode {
    const address = (field: string): TextAddress => ({ blockID: rootID, path: [...path, field] });
    switch (block.type) {
      case "paragraph": case "heading": case "quote": case "callout": return inline(address("content"), block.content);
      case "list": return <div>{block.items.map(item => <div key={item.id}>
        {block.style === "todo" && <input type="checkbox" aria-label="Completed" checked={!!item.checked} onChange={event => perform(() => session.setField(rootID, [...path, "items", item.id, "checked"], event.target.checked))} />}
        {inline({ blockID: rootID, path: [...path, "items", item.id, "content"] }, item.content)}
      </div>)}</div>;
      case "divider": return <hr />;
      case "image": return renderImage?.(block) ?? <span>{block.alt || "Image"}</span>;
      case "code": return <textarea aria-label="Code" value={block.code} onChange={event => perform(() => session.setText(address("code"), event.target.value))} />;
      case "math": return <textarea aria-label="Math" value={block.expression} onChange={event => perform(() => session.setText(address("expression"), event.target.value))} />;
      case "embed": return <span>{block.title || block.url}</span>;
      case "toggle": return <details><summary>{inline(address("summary"), block.summary)}</summary>{block.children.map(child => <div key={child.id}>{render(child, rootID, [...path, "children", child.id])}</div>)}</details>;
      case "table": return <table><tbody>{block.rows.map(row => <tr key={row.id}>{row.cells.map(cell => <td key={cell.id}>{inline({ blockID: rootID, path: [...path, "rows", row.id, "cells", cell.id, "content"] }, cell.content)}</td>)}</tr>)}</tbody></table>;
    }
  }
  return <div className="s2be" aria-label="Block editor">
    <div>
      <button disabled={!snapshot.canUndo} onClick={() => perform(() => session.undo())}>Undo</button>
      <button disabled={!snapshot.canRedo} onClick={() => perform(() => session.redo())}>Redo</button>
      <button onClick={() => perform(() => insert(snapshot.blocks.at(-1)?.id))}>Add paragraph</button>
    </div>
    {error && <div role="alert">{error}</div>}
    {snapshot.blocks.map((block, index) => <div key={block.id}>
      {render(block)}
      <button disabled={index === 0} onClick={() => perform(() => session.move(block.id, index > 1 ? snapshot.blocks[index - 2].id : undefined))}>Move up</button>
      <button onClick={() => perform(() => session.delete(block.id))}>Delete</button>
    </div>)}
  </div>;
}
