import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorSurface } from "../src/swift-react.js";
import { SwiftEditorRuntime } from "../src/swift.js";
import { inlineSelection, selectInline } from "../src/inline-react.js";
import type { Block } from "../src/schema.js";

export async function mount(bytes: ArrayBuffer) {
  const runtime = await SwiftEditorRuntime.initialize(bytes);
  const blocks: Block[] = [{ id: "p", type: "paragraph", content: [
    { type: "text", text: "Hello ", marks: [{ type: "bold" }] },
    { type: "mention", entityId: "mira", entityType: "user", label: "Mira" },
    { type: "text", text: " world", marks: [{ type: "italic" }] },
  ] }];
  const a = runtime.create({ documentID: "selection", actorID: "a", blocks });
  const b = runtime.create({ documentID: "selection", actorID: "b", blocks });
  const host = document.createElement("div"); host.id = "selection-harness"; document.body.append(host);
  createRoot(host).render(createElement(SwiftEditorSurface, { session: a }));
  const editor = () => host.querySelector<HTMLElement>('[role="textbox"]')!;
  return { a, b,
    select: (anchor: number, focus = anchor) => { editor().focus(); selectInline(editor(), Math.min(anchor, focus), Math.max(anchor, focus), anchor > focus); },
    selection: () => inlineSelection(editor()),
    remote: (start: number, end: number, text: string) => { b.replaceText({ blockID: "p", path: ["content"] }, start, end, text, []); a.receive(b.changes(a.syncState())); },
  };
}
