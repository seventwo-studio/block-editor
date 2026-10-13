import { SwiftModernSession } from "../src/swift-modern.js";
import type { ModernDocument, ModernTransport, ModernReceipt } from "../src/swift-modern.js";
import { ModernBrowserHost, ModernBrowserStore } from "../src/swift-modern-host.js";
import type { ModernBrowserCheckpoint } from "../src/swift-modern-host.js";
import { ModernBrowserRelay, type ModernRelayFetch } from "../src/swift-modern-relay.js";

function check(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
}
const same = (actual: unknown, expected: unknown, message: string) => check(canonical(actual) === canonical(expected), message);
async function rejected(action: () => Promise<void>, message: string) {
  let failed = false; try { await action(); } catch { failed = true; } check(failed, message);
}

/** Real WASM and IndexedDB; HTTP failure/delay injection is deliberate and is
 * not substituted for the separate actual client/server process/UI campaign. */
export async function runModernRelayClientContract(transport: ModernTransport) {
  const checks: string[] = [], sessions: SwiftModernSession[] = [], relays: ModernBrowserRelay[] = [];
  const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID: "relay-client-contract", title: "Title",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [], consumer: { id: "opaque-consumer", value: ["retain", "😀"] } };
  const epoch = "relay-contract-epoch", title = { node: { document: { documentID: document.documentID } }, name: "title" } as const;
  const create = (actorID: string) => { const session = SwiftModernSession.create(transport, { actorID, documentID: document.documentID, epoch, document }); sessions.push(session); return session; };
  const options = (fetch: ModernRelayFetch) => ({ documentID: document.documentID, epoch, actorID: "local", endpoint: "/relay/rooms/relay-client-contract", relayKey: "contract", token: "test-only", fetch });
  const ownPrefix = (session: SwiftModernSession) => session.execute({ command: "replaceTitle", target: session.captureTextRange(title, 0, 0), arguments: { text: "Local " } });
  try {
    const local = create("local"), server = create("server"); ownPrefix(local);
    class FailingStore extends ModernBrowserStore {
      fail = true;
      override async save(key: string, pair: ModernBrowserCheckpoint, expected?: string) {
        if (this.fail && pair.relay?.receipt.received.length) { this.fail = false; throw new Error("Injected ACK checkpoint save failure"); }
        return super.save(key, pair, expected);
      }
    }
    const store = new FailingStore(`relay-ack-${crypto.randomUUID()}`), host = new ModernBrowserHost(local, "local", store, "document");
    let posts = 0;
    const receive: ModernRelayFetch = async (_input, init) => {
      const input = JSON.parse(String(init?.body)); server.receive(input.batch); posts++;
      return Response.json({ batch: server.changes(input.state), state: server.getSnapshot().syncState, presence: [] });
    };
    const relay = new ModernBrowserRelay(host, options(receive)); relays.push(relay);
    await rejected(() => relay.exchange(), "ACK persistence failure surfaced");
    check(relay.pendingChanges === 1, "Failed ACK save cannot clear pending work");
    check((await store.load("document"))?.relay === undefined, "Failed ACK not durably published");
    same(local.getSnapshot().document, { ...document, title: "Local Title" }, "Accepted input retained after failed save");
    await relay.exchange(); check(Number(relay.pendingChanges) === 0 && posts === 2, "Explicit retry admits one original change");
    check(server.getSnapshot().syncState.received.length === 1, "Duplicate resubmit does not author a second transaction");
    same((await store.load("document"))?.relay?.receipt, server.getSnapshot().syncState, "ACK and accepted history persist together");
    checks.push("failed durable ACK, original pending input, duplicate-safe explicit retry and paired receipt");

    const stale = create("local"), latePeer = create("late-peer"); ownPrefix(stale); latePeer.receive(stale.changes());
    latePeer.execute({ command: "setAppearance", target: { document: { documentID: document.documentID } }, arguments: { field: "fontFamily", value: "serif" } });
    let entered!: () => void, release!: (value: Response) => void;
    const waiting = new Promise<void>(resolve => { entered = resolve; }), delayed = new Promise<Response>(resolve => { release = resolve; });
    const staleHost = new ModernBrowserHost(stale, "local", new ModernBrowserStore(`relay-stale-${crypto.randomUUID()}`), "document");
    const staleRelay = new ModernBrowserRelay(staleHost, options(async () => { entered(); return delayed; })); relays.push(staleRelay);
    const before = stale.save(), oldReceipt = staleRelay.serverReceipt;
    const exchange = staleRelay.exchange(); await waiting;
    staleHost.setActive(false); staleHost.setActive(true);
    release(Response.json({ batch: latePeer.changes(stale.getSnapshot().syncState), state: latePeer.getSnapshot().syncState, presence: [{ actor: "late-peer", revision: 1 }] }));
    await exchange;
    same(stale.save(), before, "A deactivated/reactivated host cannot accept an older response");
    same(staleRelay.serverReceipt, oldReceipt, "Old response cannot advance receipt");
    check(staleRelay.pendingChanges === 1 && staleRelay.peers.length === 0, "Old work and absent stale presence retained");
    checks.push("host generation ABA, delayed response discard, pending receipt and ephemeral presence");

    const guarded = create("local"), wrongPeer = create("wrong-peer"); ownPrefix(guarded); wrongPeer.receive(guarded.changes());
    wrongPeer.execute({ command: "replaceTitle", target: wrongPeer.captureTextRange(title, 11, 11), arguments: { text: " peer" } });
    const guardedHost = new ModernBrowserHost(guarded, "local", new ModernBrowserStore(`relay-scope-${crypto.randomUUID()}`), "document");
    const malformed: ModernRelayFetch = async () => Response.json({ batch: wrongPeer.changes(guarded.getSnapshot().syncState), state: { ...wrongPeer.getSnapshot().syncState, epoch: "foreign" }, presence: [] });
    const guardedRelay = new ModernBrowserRelay(guardedHost, options(malformed)); relays.push(guardedRelay);
    const accepted = guarded.save(); await rejected(() => guardedRelay.exchange(), "Wrong epoch rejected before receipt/publication");
    same(guarded.save(), accepted, "Wrong receipt cannot apply otherwise valid peer input");
    check(guardedRelay.pendingChanges === 1, "Malformed ACK leaves author work pending");
    checks.push("foreign receipt rejected before accepted content or pending receipt changes");

    const composing = create("local"), compositionPeer = create("composition-peer");
    compositionPeer.execute({ command: "replaceTitle", target: compositionPeer.captureTextRange(title, 5, 5), arguments: { text: "Peer" } });
    const heldStore = new ModernBrowserStore(`relay-held-${crypto.randomUUID()}`), heldHost = new ModernBrowserHost(composing, "local", heldStore, "document");
    heldHost.retainInput({ range: composing.captureTextRange(title, 0, 0) }, "日本", "composition draft");
    const releaseHold = composing.holdRemoteChanges(); composing.setComposing(true);
    const heldRelay = new ModernBrowserRelay(heldHost, options(async () => Response.json({ batch: compositionPeer.changes(), state: compositionPeer.getSnapshot().syncState, presence: [] }))); relays.push(heldRelay);
    await heldRelay.exchange(); const pair = await heldStore.load("document"); check(pair, "Held pair saved");
    same(composing.getSnapshot().document, document, "Held peer did not rewrite the composing buffer's accepted document");
    check(pair.deferred.length === 1 && pair.inputs[0]?.text === "日本", "Held peer packet and original input saved separately");
    heldRelay.close(); heldHost.setActive(false); composing.close(); releaseHold();
    const restored = ModernBrowserHost.restore(transport, pair, heldStore, "document"); sessions.push(restored.host.session);
    same(restored.host.session.getSnapshot().document, document, "Restored peer work remains inert until explicit release");
    check(!restored.host.session.capabilities().isComposing, "No old live composition restarted");
    restored.resumeDeferred();
    same(restored.host.session.getSnapshot().document, { ...document, title: "TitlePeer" }, "Explicit release applies preserved peer packet");
    const draft = restored.host.inputs[0]; check(draft, "Original draft survives peer release"); restored.host.retryInput(draft.id);
    same(restored.host.session.getSnapshot().document, { ...document, title: "日本TitlePeer" }, "Explicit original target retry preserves peer text and opaque metadata");
    restored.host.session.execute({ command: "undo", arguments: {} });
    same(restored.host.session.getSnapshot().document, { ...document, title: "TitlePeer" }, "Author Undo retains peer work after retry");
    const receipt: ModernReceipt = restored.host.relay!.receipt;
    same(receipt, compositionPeer.getSnapshot().syncState, "Remote ledger remains paired with held acceptance/draft history");
    checks.push("paired held peer, retained original draft, inert reopen, explicit release/retry and peer-preserving Undo");
    return { checks, qualification: "shared Swift/WASM and real IndexedDB lifecycle; HTTP fault/delay injection, not physical IME or full UI/relay proof" };
  } finally { for (const relay of relays) relay.close(); for (const session of sessions) session.close(); }
}
