import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../src/swift.js";
import { ModernBrowserStore } from "../src/swift-modern-host.js";
import { ModernBrowserRelay } from "../src/swift-modern-relay.js";
import { SwiftModernBlockEditor, type SwiftModernEditorProps } from "../src/swift-modern-react.js";
import { loadExampleAsset } from "./modern-assets.js";
import "../src/swift-modern.css";

function App() {
  const [room, setRoom] = useState(() => localStorage.getItem("modern-relay-room") ?? "shared-help");
  const [actor, setActor] = useState(() => localStorage.getItem("modern-relay-author") ?? crypto.randomUUID());
  const [token, setToken] = useState(""), [opening, setOpening] = useState(false), [error, setError] = useState<string>();
  const [relay, setRelay] = useState<ModernBrowserRelay>(), [, refresh] = useState(0);
  const [saved, setSaved] = useState<string>(), [resume, setResume] = useState<() => void>();
  const current = useRef<ModernBrowserRelay | undefined>(undefined);
  const report = useCallback((failure: unknown) => setError(String(failure)), []);
  const resolveMedia = useCallback<NonNullable<SwiftModernEditorProps["resolveMedia"]>>(async (_node, value, signal) => {
    const blob = await loadExampleAsset(String(value.src ?? "")); if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
    if (!blob) return { status: "unavailable", reason: "No application-owned local asset for this reference" };
    const url = URL.createObjectURL(blob); return { status: "available", url, dispose: () => URL.revokeObjectURL(url) };
  }, []);
  useEffect(() => () => {
    const value = current.current; value?.close(); value?.host.setActive(false); value?.host.session.close();
  }, []);
  useEffect(() => relay?.host.session.subscribe(() => { setSaved("New input or local state needs saving"); refresh(value => value + 1); }), [relay]);
  async function showSaved(value: ModernBrowserRelay): Promise<void> {
    const pair = await new ModernBrowserStore("modern-local-relay").load(`${value.host.session.getSnapshot().syncState.documentID}:${value.host.actorID}`);
    if (current.current !== value) return;
    const now = value.host.checkpoint();
    setSaved(pair && JSON.stringify({ ...now, revision: pair.revision }) === JSON.stringify(pair) ? "Local checkpoint saved" : "Newer input remains unsaved");
    refresh(revision => revision + 1);
  }
  async function open(): Promise<void> {
    setOpening(true); setError(undefined); const previous = current.current;
    try {
      if (!/^[A-Za-z0-9_-]{1,80}$/.test(room) || !actor.trim()) throw new Error("Choose a room using letters, numbers, hyphens or underscores and a nonempty author ID");
      // A document switch first saves the old host and invalidates its response
      // generation. Failure leaves that editor available for offline recovery.
      previous?.setConnected(false); if (previous) await previous.host.save();
      const response = await fetch(`${import.meta.env.BASE_URL}block-editor.wasm`);
      if (!response.ok) throw new Error("The matching WASM artifact is unavailable");
      const runtime = await SwiftEditorRuntime.initialize(await response.arrayBuffer());
      const result = await ModernBrowserRelay.open(runtime, new ModernBrowserStore("modern-local-relay"), `${room}:${actor}`, {
        documentID: room, epoch: "modern-reference-epoch", actorID: actor, token, endpoint: `/relay/rooms/${room}`, relayKey: "local-modern-reference",
      });
      const next = result.relay;
      previous?.close(); previous?.host.setActive(false); previous?.host.session.close();
      current.current = next; next.onStatus = () => { if (current.current === next) refresh(value => value + 1); };
      localStorage.setItem("modern-relay-room", room); localStorage.setItem("modern-relay-author", actor);
      setRelay(next); setResume(next.host.session.deferredChanges().length ? () => result.resumeDeferred : undefined); setSaved("Local checkpoint opened");
    } catch (failure) { report(failure); }
    finally { setOpening(false); }
  }
  async function save(): Promise<void> {
    if (!relay) return;
    try { await relay.host.save(); await showSaved(relay); }
    catch (failure) { if (current.current === relay) report(failure); }
  }
  async function synchronize(): Promise<void> {
    if (!relay) return;
    try { await relay.exchange(); await showSaved(relay); }
    catch (failure) { if (current.current === relay) report(failure); }
    finally { if (current.current === relay) refresh(value => value + 1); }
  }
  function exportRecovery(): void {
    if (!relay) return;
    const url = URL.createObjectURL(new Blob([JSON.stringify(relay.host.checkpoint())], { type: "application/json" }));
    const anchor = document.createElement("a"); anchor.href = url; anchor.download = "modern-editor-recovery.json"; anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
  async function repair(): Promise<void> {
    if (!relay) return;
    try {
      const recovery = relay.host.session.recovery(); if (!recovery) return;
      const identity = (id: { actor: string; counter: number }) => JSON.stringify([id.actor, id.counter]);
      const accepted = new Set(relay.serverReceipt.received.map(identity));
      const own = recovery.batch.changes.map(change => change.id as unknown as { actor: string; counter: number }).filter(id => id.actor === relay.host.actorID && !accepted.has(identity(id)));
      relay.host.session.repairUndo(own); await relay.host.save(); setError(undefined); refresh(value => value + 1);
    } catch (failure) { report(failure); }
  }
  return <div style={{ height: "100dvh" }}>
    <form onSubmit={event => { event.preventDefault(); void open(); }}>
      <label>Room<input aria-label="Room" value={room} onChange={event => setRoom(event.target.value)} /></label>
      <label>Author ID<input aria-label="Author ID" value={actor} onChange={event => setActor(event.target.value)} /></label>
      <label>Local demo token<input type="password" aria-label="Local demo token" value={token} onChange={event => {
        setToken(event.target.value); relay?.setToken(event.target.value);
      }} /></label>
      <button disabled={opening || relay?.exchanging}>Open editor</button>
    </form>
    {opening && <p role="status">Opening the saved editor…</p>}
    {relay && <>
      <label><input aria-label="Connected to local relay" type="checkbox" checked={relay.connected} onChange={event => {
        try { relay.setConnected(event.target.checked); setError(undefined); } catch (failure) { report(failure); }
      }} />Connected to local relay</label>
      <button disabled={relay.exchanging || !relay.connected || opening} onClick={() => void synchronize()}>Synchronize</button>
      <button disabled={opening} onClick={() => void save()}>Save locally</button>
      <button onClick={exportRecovery}>Export recovery</button>
      <p role="status" aria-label="Synchronization status">{relay.connected ? "Connected" : "Offline"}; {relay.pendingChanges} unacknowledged changes; {relay.peers.filter(peer => peer.actor !== relay.host.actorID).length} peers</p>
      {saved && <p role="status" aria-label="Local save status">{saved}</p>}
      {resume && <button onClick={() => { try { resume(); setResume(undefined); } catch (failure) { report(failure); } }}>Resume retained peer changes</button>}
      {relay.host.session.recovery() && <button onClick={() => void repair()}>Undo my rejected changes</button>}
      <SwiftModernBlockEditor session={relay.host.session} host={relay.host} readOnly={opening} onError={report} resolveMedia={resolveMedia} />
    </>}
    {error && <div role="alert">{error}<button onClick={() => setError(undefined)}>Dismiss</button></div>}
  </div>;
}
createRoot(document.getElementById("root")!).render(<App />);
