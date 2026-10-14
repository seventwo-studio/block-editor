import { SwiftModernSession, SwiftModernRecoveryError } from "./swift-modern.js";
import type { ModernBatch, ModernObject, ModernPolicy, ModernReceipt, ModernScope, ModernTransport, ModernRecovery } from "./swift-modern.js";
import { ModernBrowserHost, ModernBrowserStore } from "./swift-modern-host.js";
import { encodeModernBridgeJSON } from "./swift-modern-json.js";

export type ModernRelayFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
export interface ModernRelayOptions extends ModernScope {
  readonly endpoint: string; readonly relayKey: string; readonly token: string; readonly actorID: string;
  readonly policy?: ModernPolicy; readonly fetch?: ModernRelayFetch;
}
export class ModernRelayCapacityError extends Error {
  constructor(readonly maxBytes: number) { super(`Relay request exceeds ${maxBytes} bytes; accepted content and pending changes are retained`); this.name = "ModernRelayCapacityError"; }
}
interface Reply { batch: ModernBatch; state: ModernReceipt; presence: ModernObject[] }
const identity = (value: { actor: string; counter: number }) => JSON.stringify([value.actor, value.counter]);
const owners = new WeakMap<ModernBrowserHost, ModernBrowserRelay>();
async function replyBytes(response: Response): Promise<Uint8Array> {
  const reader = response.body?.getReader(); if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = []; let count = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      count += value.byteLength;
      if (count > 64_000_000) { await reader.cancel(); throw new Error("Relay reply exceeds shared JSON inspection capacity; local input remains retained"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(count); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

/** Optional reference HTTP lifecycle. Applications own authorization, endpoint,
 * scheduling and storage. No timer, production service or token persistence is
 * implicit. The server receipt is paired with accepted/local recovery state. */
export class ModernBrowserRelay {
  connected = true;
  exchanging = false;
  peers: readonly ModernObject[] = [];
  lastError?: string;
  transportCapacityBytes?: number;
  onStatus?: () => void;
  private readonly endpoint: string;
  private readonly fetcher: ModernRelayFetch;
  private readonly relayKey: string;
  private token: string;
  private receipt: ModernReceipt;
  private generation = 0;
  private presenceRevision = 0;
  private request?: AbortController;
  private closed = false;

  constructor(readonly host: ModernBrowserHost, options: ModernRelayOptions) {
    const endpoint = new URL(options.endpoint, typeof location === "undefined" ? undefined : location.href);
    if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) throw new Error("Relay endpoint must not contain embedded credentials or query data");
    if (!options.relayKey || options.relayKey.length > 1000) throw new Error("An application relay identity is required");
    const scope = host.session.getSnapshot().syncState;
    if (scope.documentID !== options.documentID || scope.epoch !== options.epoch || host.actorID !== options.actorID) throw new Error("Relay host scope or actor differs");
    if (host.relay && host.relay.key !== options.relayKey) throw new Error("Checkpoint belongs to another relay; preserve it before switching");
    if (owners.has(host)) throw new Error("A host already has an active relay");
    this.endpoint = endpoint.href; this.fetcher = (options.fetch ?? globalThis.fetch).bind(globalThis); this.relayKey = options.relayKey; this.token = options.token;
    this.connected = !!this.token;
    this.receipt = structuredClone(host.relay?.receipt ?? { version: 7, documentID: scope.documentID, epoch: scope.epoch, received: [] });
    host.session.changes(this.receipt);
    owners.set(host, this);
  }
  static async open(transport: ModernTransport, store: ModernBrowserStore, key: string, options: ModernRelayOptions): Promise<{ relay: ModernBrowserRelay; resumeDeferred: () => void }> {
    // A saved local pair wins even while offline; never replace it with a server
    // baseline or an empty document after loading/synchronization fails.
    const pair = await store.load(key);
    if (pair) {
      const restored = ModernBrowserHost.restore(transport, pair, store, key, options.policy);
      try { return { relay: new ModernBrowserRelay(restored.host, options), resumeDeferred: restored.resumeDeferred }; }
      catch (error) { restored.host.session.close(); throw error; }
    }
    const endpoint = new URL(options.endpoint, typeof location === "undefined" ? undefined : location.href);
    if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !["http:", "https:"].includes(endpoint.protocol)) throw new Error("Invalid relay endpoint");
    if (!options.token) throw new Error("Opening a new relay document requires an application token; saved local documents can open offline");
    const response = await (options.fetch ?? globalThis.fetch)(endpoint.href, { headers: { "x-local-token": options.token }, redirect: "error" });
    if (!response.ok) throw new Error(`Relay opening rejected (${response.status})`);
    if (!transport.inspectJSON) throw new Error("Transport lacks shared raw JSON inspection");
    const snapshot = transport.inspectJSON<ModernObject>(await replyBytes(response));
    const session = SwiftModernSession.restore(transport, snapshot, options.actorID, options.policy);
    try {
      const host = new ModernBrowserHost(session, options.actorID, store, key);
      const relay = new ModernBrowserRelay(host, options);
      host.relay = { key: options.relayKey, receipt: session.getSnapshot().syncState };
      relay.receipt = structuredClone(host.relay.receipt);
      try { await host.save(); return { relay, resumeDeferred: () => {} }; }
      catch (error) { relay.close(); throw error; }
    } catch (error) { session.close(); throw error; }
  }
  get pendingChanges(): number { return this.host.session.changes(this.receipt).changes.length; }
  get serverReceipt(): ModernReceipt { return structuredClone(this.receipt); }
  private notify(): void {
    try { this.onStatus?.(); } catch (error) { this.host.session.onListenerError(error); }
  }
  setConnected(connected: boolean): void {
    if (connected && !this.token) throw new Error("Enter an application token before connecting");
    this.connected = connected; this.generation++; this.request?.abort();
    if (!connected) this.peers = [];
    this.notify();
  }
  setToken(token: string): void {
    this.token = token; this.generation++; this.request?.abort(); this.peers = [];
    if (!token) this.connected = false;
    this.notify();
  }
  async exchange(): Promise<void> {
    if (this.closed || !this.connected || this.exchanging || !this.host.active) return;
    this.exchanging = true; this.lastError = undefined;
    const generation = this.generation, activeHost = this.host.captureSynchronization();
    const current = () => !this.closed && this.connected && generation === this.generation && activeHost();
    const request = new AbortController(); this.request = request; this.notify();
    try {
      await this.host.save(); if (!current()) return;
      const session = this.host.session, body = { actorID: this.host.actorID, batch: session.changes(this.receipt), state: session.getSnapshot().syncState,
        presence: { actor: this.host.actorID, revision: ++this.presenceRevision } };
      const response = await this.fetcher(this.endpoint, { method: "POST", headers: { "x-local-token": this.token, "content-type": "application/json" },
        body: encodeModernBridgeJSON(body), signal: request.signal, redirect: "error" });
      if (!current()) return;
      const bytes = await replyBytes(response); if (!current()) return;
      const decoded = session.inspectJSON<Reply & { error?: string; maxBytes?: number; recovery?: ModernRecovery }>(bytes); if (!current()) return;
      if (response.status === 413) {
        if (decoded.error !== "transportCapacityExceeded" || typeof decoded.maxBytes !== "number" || !Number.isSafeInteger(decoded.maxBytes) || decoded.maxBytes <= 0) throw new Error("Invalid relay capacity response");
        this.transportCapacityBytes = decoded.maxBytes; throw new ModernRelayCapacityError(decoded.maxBytes);
      }
      if (response.status === 409) {
        if (decoded.error !== "modernRecoveryRequired" || !decoded.recovery) throw new Error("Invalid modern recovery response");
        try { session.receive((decoded.recovery as ModernRecovery).batch); }
        catch (error) { if (!(error instanceof SwiftModernRecoveryError)) throw error; }
        await this.host.save();
        throw new Error("The relay has not accepted these changes; retained recovery requires explicit repair and retry");
      }
      if (!response.ok) throw new Error(`Relay exchange rejected (${response.status})`);
      const reply = decoded as Reply;
      if (!reply?.state || !reply.batch || !Array.isArray(reply.batch.changes) || !Array.isArray(reply.presence)) throw new Error("Invalid relay reply");
      // Swift validates receipt version/scope/IDs before client publication.
      session.changes(reply.state);
      const known = new Set([...session.getSnapshot().syncState.received, ...session.deferredChanges().flatMap(packet => packet.changes.map(change => change.id as unknown as { actor: string; counter: number })),
        ...reply.batch.changes.map(change => change.id as unknown as { actor: string; counter: number })].map(identity));
      if (reply.state.received.some(id => !known.has(identity(id)))) throw new Error("Relay receipt names an unreceived change");
      try { session.receive(reply.batch); }
      catch (error) { if (error instanceof SwiftModernRecoveryError) await this.host.save(); throw error; }
      const previous = this.host.relay;
      this.host.relay = { key: this.relayKey, receipt: structuredClone(reply.state) };
      try { await this.host.save(); }
      catch (error) { if (current()) this.host.relay = previous; throw error; }
      if (!current()) return;
      this.receipt = structuredClone(reply.state); this.transportCapacityBytes = undefined;
      this.peers = structuredClone(reply.presence);
    } catch (error) {
      if (!current()) return;
      this.lastError = String(error); throw error;
    } finally { this.exchanging = false; if (this.request === request) this.request = undefined; if (!this.closed && activeHost()) this.notify(); }
  }
  close(): void {
    if (this.closed) return;
    this.closed = true; this.connected = false; this.generation++; this.request?.abort(); this.peers = [];
    if (owners.get(this.host) === this) owners.delete(this.host);
  }
}
