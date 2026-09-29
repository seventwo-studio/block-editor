import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftBlockEditor } from "../src/swift-react.js";
import type { SwiftChangeBatch, SwiftEditorSession } from "../src/swift.js";
import "../src/react.css";

const initialBlocks = [{ id: "p", type: "paragraph" as const, content: [{ type: "text" as const, text: "Edit together, or work offline.", marks: [] }] }];
let engine: Promise<WebAssembly.Module> | undefined;
const loadModule = () => {
  engine ??= fetch("block-editor.wasm").then(async response => {
    if (!response.ok) throw new Error("Build the WASM artifact with bun run build:wasm first.");
    return WebAssembly.compile(await response.arrayBuffer());
  }).catch(error => { engine = undefined; throw error; });
  return engine;
};
function Demo() {
  const [left, setLeft] = useState<SwiftEditorSession>();
  const [right, setRight] = useState<SwiftEditorSession>();
  const [message, setMessage] = useState("");
  const [connected, setConnected] = useState(false);
  const [presence, setPresence] = useState("");
  const [opened, setOpened] = useState<{ version: number; snapshot: SwiftChangeBatch }>();
  const revision = useRef(0);
  function sync() {
    if (!left || !right) return;
    const a = left.changes(right.syncState()), b = right.changes(left.syncState());
    if (b.changes.length) left.receive(b);
    if (a.changes.length) right.receive(a);
    setMessage("Both editors have received all changes.");
  }
  useEffect(() => {
    if (!connected || !left || !right) { setPresence(""); return; }
    let exchanging = false;
    const exchange = () => {
      if (exchanging) return;
      exchanging = true;
      try { sync(); } catch (error) { setMessage(String(error)); }
      finally { exchanging = false; }
    };
    exchange();
    const a = left.subscribe(exchange), b = right.subscribe(exchange);
    return () => { a(); b(); };
  }, [connected, left, right]);
  function focus(actor: string) {
    if (!connected || !left || !right) return;
    const peer = actor === "alice" ? right : left;
    peer.receivePresence({ actor, revision: ++revision.current, address: { blockID: "p", path: ["content"] } });
    setPresence(`${actor === "alice" ? "Alice" : "Bob"} is editing.`);
  }
  return <main style={{ maxWidth: 1000, margin: "2rem auto", padding: "1rem", fontFamily: "system-ui" }}>
    <h1>Local and collaborative editing</h1>
    <p>Each editor works independently. Exchange changes to merge offline edits.</p>
    <button disabled={!left || !right} onClick={sync}>Exchange changes</button>
    <label><input type="checkbox" checked={connected} onChange={event => setConnected(event.target.checked)} /> Connect editors</label>
    <button disabled={!left} onClick={() => {
      if (!left) return;
      const data = new Blob([JSON.stringify(left.save())], { type: "application/json" });
      const url = URL.createObjectURL(data), link = document.createElement("a");
      link.href = url; link.download = "document.json"; link.click(); URL.revokeObjectURL(url);
    }}>Save local document</button>
    <label>Reopen local document <input type="file" accept="application/json" onChange={async event => {
      const file = event.target.files?.[0];
      if (!file) return;
      try {
        if (file.size > 64_000_000) throw new Error("Document exceeds 64 MB");
        const snapshot = JSON.parse(await file.text()) as SwiftChangeBatch;
        setConnected(false); setLeft(undefined); setRight(undefined);
        setOpened(previous => ({ version: (previous?.version ?? 0) + 1, snapshot }));
        setMessage("Reopened locally; edits remain disconnected until you connect them.");
      } catch (error) { setMessage(String(error)); }
    }} /></label>
    <p role="status">{message}</p>
    <p aria-live="polite">{presence}</p>
    <section aria-label="Alice" onFocus={() => focus("alice")}><h2>Alice</h2><SwiftBlockEditor key={opened?.version ?? 0} loadModule={loadModule} documentID="demo" actorID="alice" initialBlocks={initialBlocks} initialSnapshot={opened?.snapshot} onReady={session => { setLeft(session); }} /></section>
    <section aria-label="Bob" onFocus={() => focus("bob")}><h2>Bob</h2><SwiftBlockEditor key={opened?.version ?? 0} loadModule={loadModule} documentID="demo" actorID="bob" initialBlocks={initialBlocks} initialSnapshot={opened?.snapshot} onReady={session => { setRight(session); }} /></section>
  </main>;
}
createRoot(document.getElementById("root")!).render(<Demo />);
