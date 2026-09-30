import { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime, type SwiftEditorSession } from "../src/swift.js";
import { SwiftEditorSurface } from "../src/swift-react.js";
import { LocalSync, type RelayStatus } from "./local-sync.js";
import { claimDraft, DraftStore } from "./local-storage.js";
import "../src/react.css";

function Demo() {
  const [token, setToken] = useState("");
  const [room, setRoom] = useState(() => sessionStorage.getItem("editor-room") ?? "shared-demo");
  const [session, setSession] = useState<SwiftEditorSession>();
  const [sync, setSync] = useState<LocalSync>();
  const [status, setStatus] = useState<RelayStatus>({ connection: "offline", pending: 0, peers: [] });
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [online, setOnline] = useState(false);
  const [saved, setSaved] = useState("");
  const [drafts, setDrafts] = useState<string[]>([]);
  const [selectedDraft, setSelectedDraft] = useState("");
  const cleanup = useRef<(() => void) | undefined>(undefined);
  useEffect(() => () => cleanup.current?.(), []);
  useEffect(() => { sync?.setToken(token); }, [sync, token]);
  useEffect(() => {
    let cancelled = false;
    setSelectedDraft(""); setDrafts([]);
    void (async () => {
      const store = await DraftStore.open();
      try { const clients = await store.clients(room); if (!cancelled) setDrafts(clients); }
      finally { store.close(); }
    })().catch(error => { if (!cancelled) setError(`Local storage unavailable: ${String(error)}`); });
    return () => { cancelled = true; };
  }, [room]);
  useEffect(() => {
    if (!sync || !online) return;
    sync.connect(); void sync.exchange();
    const timer = setInterval(() => { void sync.exchange(); }, 500);
    return () => { clearInterval(timer); sync.disconnect(); };
  }, [sync, online]);
  useEffect(() => () => { sync?.disconnect(); session?.close(); }, [session, sync]);
  async function open() {
    setLoading(true); setError("");
    let release: (() => void) | undefined;
    let store: DraftStore | undefined;
    let editor: SwiftEditorSession | undefined;
    try {
      if (!/^[A-Za-z0-9_-]{1,80}$/.test(room)) throw new Error("Use a room name containing letters, numbers, hyphens or underscores.");
      const client = selectedDraft || sessionStorage.getItem("editor-client") || crypto.randomUUID();
      sessionStorage.setItem("editor-client", client); sessionStorage.setItem("editor-room", room);
      const key = `${room}:${client}`;
      release = await claimDraft(key); store = await DraftStore.open();
      const draft = await store.read(key);
      let snapshot = draft?.snapshot;
      if (!snapshot) {
        if (!token) throw new Error("Enter the local relay token to open a new draft.");
        const response = await fetch(`/relay/rooms/${room}`, { headers: { "x-local-token": token } });
        if (!response.ok) throw new Error(await response.text());
        snapshot = await response.json();
      }
      const wasm = await fetch("block-editor.wasm");
      if (!wasm.ok) throw new Error("Build the WASM engine first.");
      const runtime = await SwiftEditorRuntime.initialize(await wasm.arrayBuffer());
      const actor = draft?.actor ?? crypto.randomUUID();
      editor = runtime.restore(snapshot!, actor);
      const transport = new LocalSync(editor, `/relay/rooms/${room}`, token, actor);
      await store.write(key, { actor, snapshot: editor.save() });
      setSaved("Saved locally");
      const activeEditor = editor, activeStore = store, unlock = release;
      let writes = Promise.resolve(), revision = 0;
      const unsubscribe = editor.subscribe(() => {
        const value = { actor, snapshot: activeEditor.save() }, current = ++revision;
        setSaved("Saving locally…");
        setStatus(previous => ({ ...previous, pending: transport.pendingChanges }));
        writes = writes.catch(() => {}).then(() => activeStore.write(key, value)).then(() => {
          if (current === revision) setSaved("Saved locally");
        }).catch(error => { setSaved(`Local save failed: ${String(error)}`); });
      });
      cleanup.current = () => { unsubscribe(); void writes.finally(() => { activeStore.close(); unlock(); }); };
      transport.onStatus = setStatus;
      setStatus({ connection: "offline", pending: transport.pendingChanges, peers: [] });
      setSession(editor); setSync(transport); setOnline(!draft);
    } catch (error) { editor?.close(); store?.close(); release?.(); setError(String(error)); }
    finally { setLoading(false); }
  }
  return <main style={{ maxWidth: 900, margin: "2rem auto", padding: 20, fontFamily: "system-ui" }}>
    <h1>Local cross-platform editor lab</h1>
    <p>Open the same room on each client. Disconnect to edit independently, then reconnect to merge.</p>
    {!session && <form onSubmit={event => { event.preventDefault(); void open(); }}>
      <label>Room <input value={room} onChange={event => setRoom(event.target.value)} /></label>
      {drafts.length > 0 && <label>Saved local draft <select value={selectedDraft} onChange={event => setSelectedDraft(event.target.value)}>
        <option value="">This tab's draft or a new client</option>
        {drafts.map(client => <option key={client} value={client}>Draft {client.slice(0, 8)}</option>)}
      </select></label>}
      <label>Local demo token <input type="password" value={token} onChange={event => setToken(event.target.value)} /></label>
      <button disabled={loading}>{loading ? "Opening…" : "Open editor"}</button>
    </form>}
    {error && <p role="alert">{error}</p>}
    {session && <>
      <label>Local demo token <input type="password" value={token} onChange={event => setToken(event.target.value)} /></label>
      <label><input type="checkbox" checked={online} onChange={event => setOnline(event.target.checked)} /> Connected to local server</label>
      <p role="status">{status.connection}; {status.pending} unacknowledged changes; {status.peers.length} other clients</p>
      <p aria-live="polite" data-testid="local-save">{saved}</p>
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
