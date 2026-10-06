import { useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../src/swift.js";
import { SwiftModernBlockEditor } from "../src/swift-modern-react.js";
import { ModernBrowserHost, ModernBrowserStore } from "../src/swift-modern-host.js";
import type { ModernAsyncTarget, ModernBoundary, ModernInsertionDescriptor, ModernObject, ModernTextRange } from "../src/swift-modern.js";
import { loadExampleAsset, storeExampleAsset } from "./modern-assets.js";
import "../src/swift-modern.css";

function App() {
  const [host, setHost] = useState<ModernBrowserHost>(), [error, setError] = useState<string>(), [failure, setFailure] = useState<string>(), [retry, setRetry] = useState(0);
  const [asset, setAsset] = useState<{ host: ModernBrowserHost; descriptor?: ModernInsertionDescriptor; boundary?: ModernBoundary; range?: ModernTextRange; replacement?: ModernAsyncTarget; finish?: (value: ModernObject) => void; cancel?: (reason: Error) => void }>();
  const [resume, setResume] = useState<(() => void)>();
  const resolveMedia = useCallback(async (_node: unknown, value: ModernObject, signal: AbortSignal) => {
    if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
    const blob = await loadExampleAsset(String(value.src ?? ""));
    if (!blob) return { status: navigator.onLine ? "unavailable" as const : "offline" as const, reason: "The application has no local asset for this reference" };
    const url = URL.createObjectURL(blob); return { status: "available" as const, url, dispose: () => URL.revokeObjectURL(url) };
  }, []);
  const [url, setURL] = useState(""), [uploading, setUploading] = useState(false);
  useEffect(() => {
    let disposed = false, active: ModernBrowserHost | undefined; setError(undefined); setHost(undefined);
    (async () => {
      const response = await fetch(`${import.meta.env.BASE_URL}block-editor.wasm`); if (!response.ok) throw new Error("Build the matching WASM candidate first");
      const runtime = await SwiftEditorRuntime.initialize(await response.arrayBuffer());
      const store = new ModernBrowserStore("foliostrate-modern-example"), pair = await store.load("help");
      if (disposed) return;
      if (pair) { const restored = ModernBrowserHost.restore(runtime, pair, store, "help"); active = restored.host; setResume(() => restored.resumeDeferred); }
      else active = new ModernBrowserHost(runtime.createModern({ documentID: "help-example", actorID: "example-author", epoch: "modern-example",
        document: { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "help-example", title: "Help", appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [{ id: "intro", type: "paragraph", content: [{ type: "text", text: "Write locally. Type / to insert a block, or [[ to find a Help reference." }] }] } }), "example-author", store, "help");
      setHost(active);
    })().catch(failure => { if (!disposed) setError(String(failure)); });
    return () => { disposed = true; active?.setActive(false); active?.session.close(); };
  }, [retry]);
  async function insertAsset(metadata: ModernObject, plainLink = false): Promise<void> {
    if (!asset || !asset.host.active || asset.host.readOnly) throw new Error("The original document is no longer active");
    if (asset.finish) { asset.finish(metadata); setAsset(undefined); return; }
    const kind = asset.descriptor?.blockType;
    if (!plainLink && !kind) throw new Error("Original insertion kind unavailable");
    const value: ModernObject = plainLink ? { id: crypto.randomUUID(), type: "paragraph", content: [{ type: "text", text: String(metadata.url), marks: [{ type: "link", href: String(metadata.url) }] }] } : { id: crypto.randomUUID(), type: kind!, ...metadata, ...(kind === "image" ? { caption: [], alt: String(metadata.name ?? "Image") } : {}) };
    const result = asset.host.session.execute({ command: "paste", target: asset.range ? { range: asset.range } : { boundary: asset.boundary! }, arguments: {
      clipboard: asset.host.session.clipboardParts([{ node: { kind: "block", value } }]), policy: { allowAssetMetadata: true },
    } });
    if (result.status !== "applied" && result.status !== "noop") throw new Error(result.reason ?? result.status);
    await asset.host.save(); setAsset(undefined);
  }
  if (error) return <div role="alert">The original saved editor could not open. {error}<button onClick={() => setRetry(value => value + 1)}>Retry opening</button></div>;
  if (!host) return <p role="status">Loading editor…</p>;
  return <div style={{ height: "100dvh" }}><button onClick={() => host.save().catch(failure => setFailure(String(failure)))}>Save and retain local input</button>
    {resume && <button onClick={() => { resume(); setResume(undefined); }}>Resume retained peer changes</button>}
    <SwiftModernBlockEditor session={host.session} host={host} onError={failure => setFailure(String(failure))}
      onInsertAsset={(descriptor, boundary, range) => { setURL(""); setAsset({ host, descriptor, boundary, range }); }}
      requestMediaReplacement={target => new Promise((finish, cancel) => { setAsset({ host, replacement: target, finish, cancel }); })}
      resolveMedia={resolveMedia}
      suggestLinks={async query => [{ id: "help-getting-started", type: "help", label: "Getting started", availability: "available" as const }].filter(item => item.label.toLowerCase().includes(query.toLowerCase()))}
      onOpenReference={(id, type) => setFailure(`Application navigation hook: ${type}/${id}`)} />
    {failure && <div role="alert">{failure}<button onClick={() => setFailure(undefined)}>Dismiss</button></div>}
    {asset && <div role="dialog" aria-label="Application asset picker" className="modern-picker">
      {(asset.descriptor?.blockType === "embed" || asset.replacement?.origin.kind === "embed") ? <><label>URL<input aria-label="Preview URL" value={url} onChange={event => setURL(event.target.value)} /></label>
        <button onClick={() => void insertAsset({ url, title: url }).catch(failure => setFailure(String(failure)))}>{asset.replacement ? "Replace preview" : "Insert preview"}</button>
        {!asset.replacement && <button onClick={() => void insertAsset({ url }, true).catch(failure => setFailure(String(failure)))}>Insert plain link</button>}</> : <label>Choose local file<input aria-label="Choose local asset" type="file" accept={asset.descriptor?.blockType === "image" || asset.replacement?.origin.kind === "image" ? "image/*" : undefined} disabled={uploading} onChange={event => {
          const file = event.target.files?.[0]; if (!file) return; setUploading(true);
          void storeExampleAsset(file).then(value => insertAsset(asset.replacement?.origin.kind === "image" || asset.descriptor?.blockType === "image" ? { src: value.src, width: value.width!, height: value.height!, alt: value.name } : { src: value.src, name: value.name, mimeType: value.mimeType, size: value.size })).catch(failure => setFailure(String(failure))).finally(() => setUploading(false));
        }} /></label>}
      {uploading && <p role="status">Storing the asset before inserting it…</p>}
      <button disabled={uploading} onClick={() => { asset.cancel?.(new Error("Asset selection cancelled")); setAsset(undefined); }}>Cancel</button>
    </div>}
  </div>;
}
createRoot(document.getElementById("root")!).render(<App />);
