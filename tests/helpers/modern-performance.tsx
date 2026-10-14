/// <reference types="vite/client" />
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../../src/swift.js";
import { ModernBrowserHost, ModernBrowserStore } from "../../src/swift-modern-host.js";
import { SwiftModernBlockEditor } from "../../src/swift-modern-react.js";
import type { ModernDocument } from "../../src/swift-modern.js";
import "../../src/swift-modern.css";

async function mount(document: ModernDocument) {
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
  root.render(<SwiftModernBlockEditor session={session} host={host} onError={error => errors.push(String(error))} />);
  return { session, host, errors, dispose() { root.unmount(); session.close(); } };
}

window.mountModernPerformance = async document => { window.modernPerformance = await mount(document); };
declare global {
  interface Window {
    mountModernPerformance(document: ModernDocument): Promise<void>;
    modernPerformance: Awaited<ReturnType<typeof mount>>;
    modernPerformanceDiagnostic?: boolean;
    modernMeasurement?: { armed: boolean; result?: { elapsedMS: number; frameCount: number; error?: string; accepted?: boolean; displayed?: boolean; nativeBuffer?: string }; cleanup(): void };
  }
}
