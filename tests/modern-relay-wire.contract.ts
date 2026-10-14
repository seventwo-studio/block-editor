import { SwiftModernSession } from "../src/swift-modern.js";
import type { ModernDocument, ModernTransport } from "../src/swift-modern.js";
import { ModernBrowserHost, ModernBrowserStore } from "../src/swift-modern-host.js";
import { ModernBrowserRelay } from "../src/swift-modern-relay.js";
import { encodeModernBridgeJSON } from "../src/swift-modern-json.js";

function check(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
export async function runModernRelayWireContract(transport: ModernTransport) {
  check(transport.inspectJSON?.<{ valid: boolean }>(new TextEncoder().encode('{"valid":true}')).valid === true, "Matching raw inspection ABI must work");
  const checks: string[] = [];
  for (const mode of ["duplicate", "rounded", "utf8", "surrogate"] as const) {
    const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: `wire-${mode}`, title: "Title",
      appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [], consumer: { keep: "東京😀" } };
    const scope = { documentID: document.documentID, epoch: "wire-epoch" };
    const local = SwiftModernSession.create(transport, { ...scope, actorID: "local", document });
    const peer = SwiftModernSession.create(transport, { ...scope, actorID: "peer", document });
    peer.execute({ command: "setAppearance", target: { document: { documentID: scope.documentID } }, arguments: { field: "fontFamily", value: "serif" } });
    const host = new ModernBrowserHost(local, "local", new ModernBrowserStore(`wire-${crypto.randomUUID()}`), "document");
    let raw = JSON.stringify({ batch: peer.changes(), state: peer.getSnapshot().syncState, presence: [] });
    if (mode === "duplicate") raw = raw.replace('"batch":', '"batch":{},"batch":');
    if (mode === "rounded") raw = raw.replaceAll('"counter":1', '"counter":1.0000000000000001');
    if (mode === "surrogate") raw = raw.slice(0, -1) + ',"diagnostic":"\\ud800"}';
    let bytes = new TextEncoder().encode(raw);
    if (mode === "utf8") {
      const prefix = new TextEncoder().encode(raw.slice(0, -1) + ',"diagnostic":"');
      const suffix = new TextEncoder().encode('"}'); bytes = new Uint8Array(prefix.length + 1 + suffix.length);
      bytes.set(prefix); bytes[prefix.length] = 255; bytes.set(suffix, prefix.length + 1);
    }
    const relay = new ModernBrowserRelay(host, { ...scope, actorID: "local", endpoint: "/wire", relayKey: "wire", token: "test-only",
      fetch: async () => new Response(bytes, { headers: { "content-type": "application/json" } }) });
    try {
      const before = JSON.stringify(local.save()), receipt = JSON.stringify(relay.serverReceipt);
      let failed = false; try { await relay.exchange(); } catch { failed = true; }
      check(failed, `${mode}: original malformed wire must be rejected`);
      check(JSON.stringify(local.save()) === before, `${mode}: accepted history must stay unchanged`);
      check(JSON.stringify(relay.serverReceipt) === receipt && relay.peers.length === 0, `${mode}: no receipt/presence publication`);
      check(local.getSnapshot().document.appearance.fontFamily === "sans", `${mode}: otherwise valid peer operation must not apply`);
      checks.push(mode);
    } finally { relay.close(); local.close(); peer.close(); }
  }
  const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "wire-valid", title: "Title",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [], consumer: { zero: -0, text: "東京😀", literal: '"zero":0' } };
  const scope = { documentID: document.documentID, epoch: "wire-epoch" }, peer = SwiftModernSession.create(transport, { ...scope, actorID: "peer", document });
  const store = new ModernBrowserStore(`wire-valid-${crypto.randomUUID()}`);
  let posts = 0;
  const fetcher = async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (init?.method !== "POST") return new Response(encodeModernBridgeJSON(peer.save()));
    const body = JSON.parse(String(init.body));
    check(Object.is(body.batch.baseline.consumer.zero, -0), "Outgoing baseline must retain signed zero");
    peer.receive(body.batch); posts++;
    return new Response(encodeModernBridgeJSON({ batch: peer.changes(body.state), state: peer.getSnapshot().syncState, presence: [] }));
  };
  const options = { ...scope, actorID: "local", endpoint: "/wire", relayKey: "wire", token: "test-only", fetch: fetcher };
  const opened = await ModernBrowserRelay.open(transport, store, "document", options);
  try {
    check(Object.is((opened.relay.host.session.getSnapshot().document.consumer as { zero: number }).zero, -0), "Fresh GET retains original negative zero");
    peer.execute({ command: "setAppearance", target: { document: { documentID: scope.documentID } }, arguments: { field: "fontFamily", value: "serif" } });
    await opened.relay.exchange(); check(posts === 1 && opened.relay.host.session.getSnapshot().document.appearance.fontFamily === "serif", "Valid raw reply applies through shared admission");
    const pair = await store.load("document"); check(pair, "Signed-zero pair must save");
    const restored = ModernBrowserHost.restore(transport, pair, store, "document");
    try { check(Object.is((restored.host.session.getSnapshot().document.consumer as { zero: number }).zero, -0), "Signed zero survives save and explicit reopen"); }
    finally { restored.host.session.close(); }
    checks.push("valid signed-zero GET/exchange/paired reopen");
  } finally { opened.relay.close(); opened.relay.host.session.close(); peer.close(); }
  const rejectedStore = new ModernBrowserStore(`wire-open-${crypto.randomUUID()}`), seed = SwiftModernSession.create(transport, { ...scope, actorID: "seed", document });
  try {
    const raw = encodeModernBridgeJSON(seed.save()).replace('"baseline":', '"baseline":{},"baseline":');
    let failed = false;
    try { await ModernBrowserRelay.open(transport, rejectedStore, "document", { ...options, fetch: async () => new Response(raw) }); } catch { failed = true; }
    check(failed && !await rejectedStore.load("document"), "Malformed fresh GET cannot install a normalized baseline");
    checks.push("malformed fresh GET without local replacement");
  } finally { seed.close(); }
  return { checks };
}
