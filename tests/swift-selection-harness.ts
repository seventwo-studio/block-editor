import { createElement, useLayoutEffect } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorSurface } from "../src/swift-react.js";
import { SwiftEditorRuntime, type SwiftEditorSession } from "../src/swift.js";
import { inlineSelection, selectInline } from "../src/inline-react.js";
import type { Block } from "../src/schema.js";

export async function mount(bytes: ArrayBuffer, onMount?: (a: SwiftEditorSession, b: SwiftEditorSession, host: HTMLDivElement) => void) {
  const runtime = await SwiftEditorRuntime.initialize(bytes);
  const blocks: Block[] = [{ id: "p", type: "paragraph", content: [
    { type: "text", text: "Hello ", marks: [{ type: "bold" }] },
    { type: "mention", entityId: "mira", entityType: "user", label: "Mira" },
    { type: "text", text: " world", marks: [{ type: "italic" }] },
  ] }, { id: "code", type: "code", language: "swift", code: "Hello world" }, { id: "math", type: "math", expression: "x + y" }];
  const a = runtime.create({ documentID: "selection", actorID: "a", blocks });
  const b = runtime.create({ documentID: "selection", actorID: "b", blocks });
  const host = document.createElement("div"); host.id = "selection-harness"; document.body.append(host);
  function MountedSurface() {
    // Hosts can deliver a batch during layout, before passive effects run.
    useLayoutEffect(() => { onMount?.(a, b, host); }, []);
    return createElement(SwiftEditorSurface, { session: a });
  }
  createRoot(host).render(createElement(MountedSurface));
  const editor = () => host.querySelector<HTMLElement>('[role="textbox"]')!;
  return { a, b,
    select: (anchor: number, focus = anchor) => { editor().focus(); selectInline(editor(), Math.min(anchor, focus), Math.max(anchor, focus), anchor > focus); },
    selection: () => inlineSelection(editor()),
    remote: (start: number, end: number, text: string) => { b.replaceText({ blockID: "p", path: ["content"] }, start, end, text, []); a.receive(b.changes(a.syncState())); },
  };
}
