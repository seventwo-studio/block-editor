/// <reference types="vite/client" />
import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../../src/swift.js";
import { ModernBrowserHost, ModernBrowserStore } from "../../src/swift-modern-host.js";
import { SwiftModernBlockEditor } from "../../src/swift-modern-react.js";
import type { ModernDocument } from "../../src/swift-modern.js";
import "../../src/swift-modern.css";

async function mount(document: ModernDocument) {
  const runtime = await SwiftEditorRuntime.initialize(await (await fetch("/modern-engine.wasm")).arrayBuffer());
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
    modernMeasurement?: { armed: boolean; result?: { elapsedMS: number; frameCount: number; error?: string }; cleanup(): void };
  }
}
