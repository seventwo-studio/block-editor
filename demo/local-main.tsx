import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime, type SwiftEditorSession } from "../src/swift.js";
import { SwiftEditorSurface } from "../src/swift-react.js";
import { LocalSync, type RelayStatus } from "./local-sync.js";
import "../src/react.css";

function Demo() {
  const [token, setToken] = useState("");
  const [room, setRoom] = useState("shared-demo");
  const [session, setSession] = useState<SwiftEditorSession>();
  const [sync, setSync] = useState<LocalSync>();
  const [status, setStatus] = useState<RelayStatus>({ connection: "offline", pending: 0, peers: [] });
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [online, setOnline] = useState(false);
  useEffect(() => {
    if (!sync || !online) return;
    sync.connect(); void sync.exchange();
    const timer = setInterval(() => { void sync.exchange(); }, 500);
    return () => { clearInterval(timer); sync.disconnect(); };
  }, [sync, online]);
  useEffect(() => () => { sync?.disconnect(); session?.close(); }, [session, sync]);
  async function open() {
    setLoading(true); setError("");
    try {
      if (!/^[A-Za-z0-9_-]{1,80}$/.test(room)) throw new Error("Use a room name containing letters, numbers, hyphens or underscores.");
      const response = await fetch(`/relay/rooms/${room}`, { headers: { "x-local-token": token } });
      if (!response.ok) throw new Error(await response.text());
      const snapshot = await response.json();
      const wasm = await fetch("block-editor.wasm");
      if (!wasm.ok) throw new Error("Build the WASM engine first.");
      const runtime = await SwiftEditorRuntime.initialize(await wasm.arrayBuffer());
      const actor = crypto.randomUUID();
      const editor = runtime.restore(snapshot, actor);
      const transport = new LocalSync(editor, `/relay/rooms/${room}`, token, actor);
      transport.onStatus = setStatus;
      setSession(editor); setSync(transport); setOnline(true);
    } catch (error) { setError(String(error)); }
    finally { setLoading(false); }
  }
  return <main style={{ maxWidth: 900, margin: "2rem auto", padding: 20, fontFamily: "system-ui" }}>
    <h1>Local cross-platform editor lab</h1>
    <p>Open the same room on each client. Disconnect to edit independently, then reconnect to merge.</p>
    {!session && <form onSubmit={event => { event.preventDefault(); void open(); }}>
      <label>Room <input value={room} onChange={event => setRoom(event.target.value)} /></label>
      <label>Local demo token <input type="password" value={token} onChange={event => setToken(event.target.value)} /></label>
      <button disabled={loading || !token}>{loading ? "Opening…" : "Open editor"}</button>
    </form>}
    {error && <p role="alert">{error}</p>}
    {session && <>
      <label><input type="checkbox" checked={online} onChange={event => setOnline(event.target.checked)} /> Connected to local server</label>
      <p role="status">{status.connection}; {status.pending} unacknowledged changes; {status.peers.length} other clients</p>
      {status.error && <p role="alert">{status.error}</p>}
      <button onClick={() => {
        const block = session.getSnapshot().blocks.find(block => block.id === "p");
        if (!block || block.type !== "paragraph") return;
        // Small interactive burst; larger repeatable scenarios use demo:stress.
        for (let index = 0; index < 20; index++) session.replaceText({ blockID: "p", path: ["content"] }, 0, 0, `[${index}]`);
      }}>Insert 20 stress edits</button>
      <SwiftEditorSurface session={session} />
    </>}
  </main>;
}
createRoot(document.getElementById("root")!).render(<Demo />);
