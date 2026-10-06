import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../src/swift.js";
import { SwiftModernBlockEditor } from "../src/swift-modern-react.js";
import { ModernBrowserHost, ModernBrowserStore } from "../src/swift-modern-host.js";
import "../src/swift-modern.css";

function App() {
  const [host, setHost] = useState<ModernBrowserHost>(), [error, setError] = useState<string>();
  useEffect(() => {
    let disposed = false, active: ModernBrowserHost | undefined;
    (async () => {
      const response = await fetch(`${import.meta.env.BASE_URL}block-editor.wasm`); if (!response.ok) throw new Error("Build the matching WASM candidate first");
      const runtime = await SwiftEditorRuntime.initialize(await response.arrayBuffer());
      const store = new ModernBrowserStore("foliostrate-modern-example"), pair = await store.load("help");
      if (disposed) return;
      if (pair) { const restored = ModernBrowserHost.restore(runtime, pair, store, "help"); active = restored.host; restored.resumeDeferred(); }
      else active = new ModernBrowserHost(runtime.createModern({ documentID: "help-example", actorID: "example-author", epoch: "modern-example",
        document: { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "help-example", title: "Help", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [{ id: "intro", type: "paragraph", content: [{ type: "text", text: "Write locally. Type / to insert a block, or [[ to find a Help reference." }] }] } }), "example-author", store, "help");
      setHost(active);
    })().catch(failure => { if (!disposed) setError(String(failure)); });
    return () => { disposed = true; active?.setActive(false); };
  }, []);
  if (error) return <p role="alert">{error}</p>;
  if (!host) return <p role="status">Loading editor…</p>;
  return <div style={{ height: "100dvh" }}><button onClick={() => host.save().catch(failure => setError(String(failure)))}>Save and retain local input</button>
    <SwiftModernBlockEditor session={host.session} host={host} onError={failure => setError(String(failure))}
      suggestLinks={async query => [{ id: "help-getting-started", type: "help", label: "Getting started", availability: "available" as const }].filter(item => item.label.toLowerCase().includes(query.toLowerCase()))}
      onOpenReference={(id, type) => setError(`Application navigation hook: ${type}/${id}`)} /></div>;
}
createRoot(document.getElementById("root")!).render(<App />);
