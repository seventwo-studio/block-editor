import { createRoot } from "react-dom/client";
import { SwiftEditorRuntime } from "../../src/swift.js";
import { SwiftModernSession } from "../../src/swift-modern.js";
import type { ModernDocument } from "../../src/swift-modern.js";
import { SwiftModernBlockEditor } from "../../src/swift-modern-react.js";
import { ModernBrowserHost, ModernBrowserStore } from "../../src/swift-modern-host.js";

/** Test-only host using actual React interaction and shared Swift/WASM mutations.
 * The peer seam represents another author, never substitutes local DOM input. */
export async function mountModernSurface(document: ModernDocument) {
  const runtime = await SwiftEditorRuntime.initialize(await (await fetch("modern-engine.wasm")).arrayBuffer());
  const scope = { documentID: document.documentID, epoch: "surface-acceptance", document };
  const session = SwiftModernSession.create(runtime, { ...scope, actorID: "local" });
  const peer = SwiftModernSession.create(runtime, { ...scope, actorID: "peer" });
  const host = new ModernBrowserHost(session, "local", new ModernBrowserStore(`surface-${crypto.randomUUID()}`), "document");
  const errors: string[] = [], events: { type: string; key?: string; target: string; value?: string }[] = [];
  const record = (event: Event) => {
    const target = event.target instanceof HTMLElement ? event.target : undefined;
    events.push({ type: event.type, key: event instanceof KeyboardEvent ? event.key : undefined,
      target: target?.getAttribute("aria-label") ?? target?.tagName ?? "window", value: target instanceof HTMLInputElement ? target.value : undefined });
  };
  const eventTypes = ["pointerdown", "pointerup", "pointercancel", "keydown", "keyup", "input", "change"];
  for (const type of eventTypes) window.addEventListener(type, record, true);
  const root = createRoot(window.document.getElementById("root")!);
  root.render(<SwiftModernBlockEditor session={session} host={host} onError={error => errors.push(String(error))}
    suggestLinks={async query => [{ id: "linked", type: "page", label: `Page ${query}`, availability: "available" }]} />);
  return { session, peer, errors, events, dispose() { for (const type of eventTypes) window.removeEventListener(type, record, true); root.unmount(); session.close(); peer.close(); } };
}

declare global { interface Window { modernAcceptance: Awaited<ReturnType<typeof mountModernSurface>> } }
