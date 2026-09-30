import type { SwiftChangeBatch, SwiftEditorSession, SwiftPresence, SwiftSyncState } from "../src/swift.js";

export interface RelayStatus {
  connection: "offline" | "syncing" | "connected" | "error";
  pending: number;
  peers: SwiftPresence[];
  error?: string;
}

/** Optional demo transport. Editing continues in the session when this is disconnected. */
export class LocalSync {
  private receipt: SwiftSyncState = { received: [] };
  private controller?: AbortController;
  private online = false;
  private revision = 0;
  private peerActors = new Set<string>();
  onStatus?: (status: RelayStatus) => void;
  constructor(readonly session: SwiftEditorSession, private endpoint: string, private token: string, private actorID: string) {}
  get pendingChanges() { return this.session.changes(this.receipt).changes.length; }
  setToken(token: string) { this.token = token; }
  connect() { this.online = true; }
  disconnect() {
    this.online = false;
    this.controller?.abort(); this.controller = undefined;
    for (const actor of this.peerActors) this.session.removePresence(actor);
    this.peerActors.clear();
    this.emit("offline", []);
  }
  private emit(connection: RelayStatus["connection"], peers: SwiftPresence[], error?: string) {
    this.onStatus?.({ connection, peers, pending: this.session.changes(this.receipt).changes.length, error });
  }
  async exchange() {
    if (!this.online || this.controller) return;
    const controller = new AbortController(); this.controller = controller;
    this.emit("syncing", []);
    try {
      const response = await fetch(this.endpoint, {
        method: "POST", signal: controller.signal,
        headers: { "content-type": "application/json", "x-local-token": this.token },
        body: JSON.stringify({ actorID: this.actorID, batch: this.session.changes(this.receipt), state: this.session.syncState(),
          presence: { actor: this.actorID, revision: ++this.revision, address: { blockID: "p", path: ["content"] } } }),
      });
      if (!response.ok) throw new Error(await response.text());
      const value = await response.json() as { batch: SwiftChangeBatch; state: SwiftSyncState; presence: SwiftPresence[] };
      if (!this.online || controller.signal.aborted) return;
      this.session.receive(value.batch); this.receipt = value.state;
      const peers = value.presence.filter(peer => peer.actor !== this.actorID);
      const actors = new Set(peers.map(peer => peer.actor));
      for (const actor of this.peerActors) if (!actors.has(actor)) this.session.removePresence(actor);
      for (const peer of peers) this.session.receivePresence(peer);
      this.peerActors = actors;
      this.emit("connected", peers);
    } catch (error) {
      if (!controller.signal.aborted) this.emit("error", [], String(error));
    } finally { if (this.controller === controller) this.controller = undefined; }
  }
}
