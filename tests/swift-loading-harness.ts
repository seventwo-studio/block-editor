import { createElement, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { SwiftBlockEditor, type SwiftBlockEditorProps } from "../src/swift-react.js";
import { SwiftEditorRuntime, SwiftEditorSession } from "../src/swift.js";

type Options = {
  load?: "deferred" | "throwOnce" | "rejectOnce" | "invalidBytes" | "missingExports";
  fail?: "create" | "restore" | "ready" | "disconnect";
  strict?: boolean;
  deferInitialize?: boolean;
  unmountOnReady?: boolean;
};

/** Exercise React ownership and failure handling without compiling the Swift engine. */
export function mount(options: Options = {}) {
  const host = document.createElement("div"); host.id = "loading-harness"; document.body.append(host);
  const root = createRoot(host);
  const events: string[] = [];
  const pending: { resolve: (value: ArrayBuffer) => void; reject: (reason: Error) => void }[] = [];
  const initialize = SwiftEditorRuntime.initialize;
  let finishInitialize: (() => void) | undefined;
  let attempts = 0, doc = "first", fail = options.fail;
  const bytes = new ArrayBuffer(0);
  const runtime = {
    call: (request: Record<string, unknown>) => {
      if (request.command === "close") events.push(`close:${request.session}`);
    },
    create: ({ documentID }: { documentID: string }) => {
      events.push(`create:${documentID}`);
      if (fail === "create") throw new Error("create failed");
      return new SwiftEditorSession(runtime as unknown as SwiftEditorRuntime, documentID, { blocks: [], canUndo: false, canRedo: false });
    },
    restore: () => { events.push("restore"); throw new Error("incompatible snapshot version"); },
  };
  SwiftEditorRuntime.initialize = async source => {
    events.push("initialize");
    if (options.load === "invalidBytes" || options.load === "missingExports") return initialize(source);
    if (options.deferInitialize) await new Promise<void>(resolve => { finishInitialize = resolve; });
    return runtime as unknown as SwiftEditorRuntime;
  };
  const loadModule = () => {
    events.push("load"); attempts++;
    if (options.load === "throwOnce" && attempts === 1) throw new Error("synchronous load failed");
    if (options.load === "rejectOnce" && attempts === 1) return Promise.reject(new Error("network unavailable"));
    if (options.load === "deferred") return new Promise<ArrayBuffer>((resolve, reject) => pending.push({ resolve, reject }));
    if (options.load === "missingExports") return Promise.resolve(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    return Promise.resolve(bytes);
  };
  function render() {
    const props: SwiftBlockEditorProps = {
      loadModule, documentID: doc, actorID: "author", initialBlocks: [],
      initialSnapshot: fail === "restore" ? { version: 99, documentID: doc, baseline: null, changes: [] } : undefined,
      onReady: () => {
        const opened = doc;
        events.push(`ready:${opened}`);
        if (fail === "ready") throw new Error("host connection failed");
        if (options.unmountOnReady) root.unmount();
        return () => { events.push(`disconnect:${opened}`); if (fail === "disconnect") throw new Error("disconnect failed"); };
      },
    };
    const editor = createElement(SwiftBlockEditor, props);
    root.render(options.strict ? createElement(StrictMode, null, editor) : editor);
  }
  render();
  return {
    events,
    resolve: (index = 0) => pending[index].resolve(bytes),
    reject: (index = 0) => pending[index].reject(new Error("old request failed")),
    replace: (id: string) => { doc = id; render(); },
    clearFailure: () => { fail = undefined; render(); },
    finishInitialize: () => finishInitialize?.(),
    unmount: () => root.unmount(),
  };
}
