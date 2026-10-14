/// <reference types="vite/client" />
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../../src/swift.js";
import { ModernBrowserHost, ModernBrowserStore } from "../../src/swift-modern-host.js";
import { SwiftModernBlockEditor } from "../../src/swift-modern-react.js";
import type { ModernDocument } from "../../src/swift-modern.js";
import "../../src/swift-modern.css";

async function mount(document: ModernDocument, options: { controlledImages?: boolean } = {}) {
  const runtime = await SwiftEditorRuntime.initialize(await (await fetch("/modern-engine.wasm")).arrayBuffer());
  if (window.modernPerformanceDiagnostic) {
    const call = runtime.call.bind(runtime), totals: Record<string, { calls: number; ms: number }> = {};
    let count = 0;
    runtime.call = <T,>(request: Record<string, unknown>): T => {
      const start = performance.now();
      try { return call<T>(request); }
      finally {
        const command = String(request.command), elapsed = performance.now() - start;
        const total = totals[command] ??= { calls: 0, ms: 0 }; total.calls++; total.ms += elapsed;
        if (++count % 500 === 0 || elapsed > 100) console.info("modern-read-profile", JSON.stringify({ count, command, elapsed, totals }));
      }
    };
  }
  const session = runtime.createModern({ documentID: document.documentID, actorID: "measurement", epoch: "surface-performance", document });
  const host = new ModernBrowserHost(session, "measurement", new ModernBrowserStore(`measurement-${crypto.randomUUID()}`), "document");
  const errors: string[] = [], root = createRoot(window.document.getElementById("root")!);
  const resources = { created: 0, released: 0, active: 0, aborted: 0 };
  const resolveMedia = options.controlledImages ? async (_node: unknown, value: { readonly type?: unknown }, signal: AbortSignal) => {
    if (value.type !== "image") return { status: "unavailable" as const, reason: "Controlled benchmark supplies images only" };
    await new Promise<void>(resolve => setTimeout(resolve, 5));
    if (signal.aborted) { resources.aborted++; throw new DOMException("Unmounted benchmark image", "AbortError"); }
    const url = URL.createObjectURL(new Blob(['<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#71867b"/></svg>'], { type: "image/svg+xml" }));
    resources.created++; resources.active++; let released = false;
    return { status: "available" as const, url, dispose() { if (!released) { released = true; URL.revokeObjectURL(url); resources.released++; resources.active--; } } };
  } : undefined;
  root.render(<SwiftModernBlockEditor session={session} host={host} resolveMedia={resolveMedia} onError={error => errors.push(String(error))} />);
  let disposed = false;
  return { runtime, session, host, errors, resources, dispose() { if (disposed) return; disposed = true; host.setActive(false); root.unmount(); session.close(); } };
}

window.mountModernPerformance = async (document, options) => { window.modernPerformance = await mount(document, options); };
declare global {
  interface Window {
    mountModernPerformance(document: ModernDocument, options?: { controlledImages?: boolean }): Promise<void>;
    modernPerformance: Awaited<ReturnType<typeof mount>>;
    modernPerformanceDiagnostic?: boolean;
    modernMeasurement?: { armed: boolean; result?: { elapsedMS: number; frameCount: number; error?: string; accepted?: boolean; displayed?: boolean; nativeBuffer?: string }; cleanup(): void };
  }
}
