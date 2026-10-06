import { SwiftModernSession, SwiftModernCutover, type ModernObject, type ModernAsyncTarget, type ModernAsyncRecord, type ModernPasteTarget, type ModernClipboard, type ModernHistorySelectionArchive, type ModernAsyncArchive, type ModernBatch, type ModernRecovery, type ModernDeleteTarget, type ModernPolicy, type ModernTransport } from "./swift-modern.js";
import { parseClipboardHtml } from "./clipboard.js";

export interface ModernRetainedInput { readonly id: string; readonly target: ModernPasteTarget; readonly text: string; readonly reason: string }
export interface ModernRetainedPaste { readonly id: string; readonly target: ModernPasteTarget; readonly clipboard?: ModernClipboard; readonly rawHTML?: string; readonly plainText?: string; readonly mode?: "rich" | "plainText"; readonly reason: string }
export interface ModernBrowserCheckpoint {
  readonly version: 1; readonly revision: string; readonly documentID: string; readonly actorID: string; readonly epoch: string;
  readonly accepted: ModernObject; readonly historySelection: ModernHistorySelectionArchive; readonly providers: ModernAsyncArchive;
  readonly recovery: ModernRecovery | null; readonly deferred: readonly ModernBatch[];
  readonly inputs: readonly ModernRetainedInput[]; readonly clipboard: readonly ModernRetainedPaste[];
}
export interface ModernBrowserActivation {
  readonly revision: string; readonly documentID: string; readonly epoch: string; readonly liveKey: string;
  readonly previous?: ModernBrowserActivation;
}
const encodeBase64 = (bytes: Uint8Array): string => btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join(""));
/** One IndexedDB transaction pairs all local sidecars with accepted history.
 * Compare-and-swap prevents another tab from overwriting a revision it did not load. */
export class ModernBrowserStore {
  constructor(private readonly databaseName: string) {}
  private async open(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(this.databaseName, 1);
      request.onupgradeneeded = () => { request.result.createObjectStore("pairs"); request.result.createObjectStore("archives"); request.result.createObjectStore("activation"); };
      request.onerror = () => reject(request.error); request.onsuccess = () => resolve(request.result);
    });
  }
  async load(key: string): Promise<ModernBrowserCheckpoint | undefined> {
    const db = await this.open();
    try { return await new Promise((resolve, reject) => {
      const request = db.transaction("pairs").objectStore("pairs").get(key);
      request.onsuccess = () => resolve(request.result as ModernBrowserCheckpoint | undefined); request.onerror = () => reject(request.error);
    }); } finally { db.close(); }
  }
  async save(key: string, value: ModernBrowserCheckpoint, expected?: string): Promise<void> {
    if (JSON.stringify(value).length > 384_000_000) throw new Error("Checkpoint capacity exceeded");
    const db = await this.open();
    try { await new Promise<void>((resolve, reject) => {
      const tx = db.transaction("pairs", "readwrite", { durability: "strict" }), pairs = tx.objectStore("pairs");
      const request = pairs.get(key); let conflict = false;
      request.onsuccess = () => {
        if ((request.result as ModernBrowserCheckpoint | undefined)?.revision !== expected) { conflict = true; tx.abort(); }
        else pairs.put(value, key);
      };
      tx.oncomplete = () => resolve(); tx.onabort = () => reject(new Error(conflict ? "Checkpoint revision changed" : "Checkpoint transaction aborted")); tx.onerror = () => reject(tx.error);
    });
    const saved = await this.load(key);
    if (!saved || JSON.stringify(saved) !== JSON.stringify(value)) throw new Error("Checkpoint readback mismatch");
    } finally { db.close(); }
  }
  private async read<T>(store: "pairs" | "archives" | "activation", key: string): Promise<T | undefined> {
    const db = await this.open();
    try { return await new Promise((resolve, reject) => {
      const request = db.transaction(store).objectStore(store).get(key);
      request.onsuccess = () => resolve(request.result as T | undefined); request.onerror = () => reject(request.error);
    }); } finally { db.close(); }
  }
  async active(key: string): Promise<ModernBrowserActivation | undefined> { return this.read("activation", key); }
  async loadActive(key: string): Promise<ModernBrowserCheckpoint | undefined> {
    const pointer = await this.active(key); if (!pointer) return;
    const pair = await this.load(pointer.liveKey);
    if (!pair || pair.documentID !== pointer.documentID || pair.epoch !== pointer.epoch) throw new Error("Invalid activation checkpoint");
    return pair;
  }
  /** Originals and the detached candidate are read back before pointer activation.
   * Immutable revisions remain available even if a later pointer write fails. */
  async activate(key: string, archive: string, candidate: ModernBrowserCheckpoint, expected: string | undefined, oldWritersStopped: true, transport: ModernTransport): Promise<ModernBrowserActivation> {
    if (!oldWritersStopped || new TextEncoder().encode(archive).length > 64_000_000) throw new Error("Migration precondition failed");
    const pair = structuredClone(candidate), cutover = new SwiftModernCutover(transport), bytes = new TextEncoder().encode(archive);
    const upload = cutover.begin(bytes.length);
    try {
      for (let offset = 0; offset < bytes.length; offset += 1_000_000) cutover.append(upload.archiveID, offset, encodeBase64(bytes.subarray(offset, offset + 1_000_000)));
      const prepared = cutover.prepareUploaded(upload.archiveID);
      if (prepared.status === "unavailable" || prepared.document.documentID !== pair.documentID) throw new Error("Incompatible migration archive");
      // Restore every sidecar through the shared engine before durable activation.
      const detached = ModernBrowserHost.restore(transport, pair, this, "validation");
      try { if (detached.host.session.getSnapshot().syncState.received.length || JSON.stringify(detached.host.session.getSnapshot().document) !== JSON.stringify(prepared.document)) throw new Error("Migration candidate differs from original projection"); }
      finally { detached.host.session.close(); }
      const canonicalCount = cutover.bytes(upload.archiveID, 0, 0).byteCount;
      const canonicalBytes = new Uint8Array(canonicalCount);
      for (let offset = 0; offset < canonicalCount; offset += 1_000_000) {
        const chunk = cutover.bytes(upload.archiveID, offset, Math.min(1_000_000, canonicalCount - offset));
        canonicalBytes.set(Uint8Array.from(atob(chunk.bytes), value => value.charCodeAt(0)), offset);
      }
      archive = new TextDecoder("utf-8", { fatal: true }).decode(canonicalBytes);
      const scope = JSON.parse(archive) as { documentID: string; epoch: string };
      if (scope.documentID !== pair.documentID || scope.epoch !== pair.epoch) throw new Error("Migration scope mismatch");
      const previous = await this.active(key);
      if (previous?.revision === pair.revision) return previous;
      if (previous?.revision !== expected || previous?.epoch === pair.epoch) throw new Error("Migration revision changed or epoch reused");
      const revision = pair.revision, liveKey = `modern:${pair.documentID}:${pair.epoch}`;
      const pointer: ModernBrowserActivation = { revision, documentID: pair.documentID, epoch: pair.epoch, liveKey, ...(previous ? { previous } : {}) };
      const db = await this.open();
      try {
        await new Promise<void>((resolve, reject) => {
          const tx = db.transaction(["archives", "pairs"], "readwrite", { durability: "strict" });
          const stage = (store: IDBObjectStore, stagedKey: string, value: unknown) => {
            const request = store.get(stagedKey);
            request.onsuccess = () => {
              if (request.result !== undefined && JSON.stringify(request.result) !== JSON.stringify(value)) tx.abort();
              else store.put(value, stagedKey);
            };
          };
          stage(tx.objectStore("archives"), revision, archive); stage(tx.objectStore("pairs"), revision, pair); stage(tx.objectStore("pairs"), liveKey, pair);
          tx.oncomplete = () => resolve(); tx.onabort = () => reject(tx.error ?? new Error("Migration persistence aborted")); tx.onerror = () => reject(tx.error);
        });
        const savedArchive = await this.read<string>("archives", revision), savedPair = await this.load(revision);
        if (savedArchive !== archive || JSON.stringify(savedPair) !== JSON.stringify(pair)) throw new Error("Migration readback mismatch");
        const savedBytes = new TextEncoder().encode(savedArchive);
        for (let offset = 0; offset < savedBytes.length; offset += 1_000_000) cutover.verifyReadback(upload.archiveID, offset, encodeBase64(savedBytes.subarray(offset, offset + 1_000_000)));
        await this.publishPointer(db, key, pointer, expected);
        const saved = await this.active(key);
        if (saved?.revision !== revision) throw new Error("Activation readback mismatch");
        return pointer;
      } finally { db.close(); }
    } finally { cutover.forget(upload.archiveID); }
  }
  async rollback(key: string, expected: string, oldWritersStopped: true): Promise<ModernBrowserActivation> {
    if (!oldWritersStopped) throw new Error("Old writers must be stopped");
    const current = await this.active(key);
    if (current?.revision !== expected || !current.previous) throw new Error("No matching rollback pointer");
    const previous = current.previous, pair = await this.load(previous.liveKey), original = await this.read<string>("archives", previous.revision);
    if (!pair || !original || pair.documentID !== previous.documentID || pair.epoch !== previous.epoch) throw new Error("Rollback checkpoint unavailable");
    const db = await this.open();
    try { await this.publishPointer(db, key, previous, expected); } finally { db.close(); }
    if ((await this.active(key))?.revision !== previous.revision) throw new Error("Rollback readback mismatch");
    return previous;
  }
  private publishPointer(db: IDBDatabase, key: string, value: ModernBrowserActivation, expected?: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const tx = db.transaction("activation", "readwrite", { durability: "strict" }), store = tx.objectStore("activation"), request = store.get(key);
      request.onsuccess = () => { if ((request.result as ModernBrowserActivation | undefined)?.revision !== expected) tx.abort(); else store.put(value, key); };
      tx.oncomplete = () => resolve(); tx.onabort = () => reject(tx.error ?? new Error("Activation revision conflict")); tx.onerror = () => reject(tx.error);
    });
  }
}

/** Explicit application lifecycle adapter. It owns no transport or autosave
 * timer. The application deactivates it before switching mounted documents. */
export class ModernBrowserHost {
  inputs: ModernRetainedInput[] = [];
  clipboard: ModernRetainedPaste[] = [];
  active = true;
  readOnly = false;
  private readonly running = new Set<string>();
  private readonly unsaved = new Map<string, { target: ModernAsyncTarget; metadata: ModernObject }>();
  private generation = 0;
  private revision?: string;
  private tail: Promise<void> = Promise.resolve();
  constructor(readonly session: SwiftModernSession, readonly actorID: string, private readonly store: ModernBrowserStore, private readonly key: string, loadedRevision?: string) { this.revision = loadedRevision; }
  setActive(active: boolean): void { if (active !== this.active) { this.active = active; this.generation++; } }
  captureInvocation(): () => boolean {
    const generation = this.generation;
    return () => this.active && !this.readOnly && generation === this.generation;
  }
  checkpoint(): ModernBrowserCheckpoint {
    const scope = this.session.getSnapshot().syncState;
    const pair: ModernBrowserCheckpoint = { version: 1, revision: crypto.randomUUID(), documentID: scope.documentID, actorID: this.actorID, epoch: scope.epoch,
      accepted: this.session.save(), historySelection: this.session.exportHistorySelection(), providers: this.session.exportAsyncRequests(),
      recovery: this.session.recovery(), deferred: this.session.deferredChanges(), inputs: structuredClone(this.inputs), clipboard: structuredClone(this.clipboard) };
    validateCheckpoint(pair); return pair;
  }
  save(): Promise<void> {
    const operation = this.tail.catch(() => {}).then(async () => {
      const pair = this.checkpoint();
      try { await this.store.save(this.key, pair, this.revision); this.revision = pair.revision; }
      catch (error) {
        if ((await this.store.load(this.key))?.revision === pair.revision) this.revision = pair.revision;
        throw error;
      }
    });
    this.tail = operation; return operation;
  }
  static restore(transport: ModernTransport, pair: ModernBrowserCheckpoint, store: ModernBrowserStore, key: string, policy: ModernPolicy = {}): { host: ModernBrowserHost; resumeDeferred: () => void } {
    validateCheckpoint(pair);
    const session = SwiftModernSession.restore(transport, pair.accepted, pair.actorID, policy);
    try {
      const scope = session.getSnapshot().syncState;
      if (scope.documentID !== pair.documentID || scope.epoch !== pair.epoch) throw new Error("Checkpoint scope mismatch");
      session.restoreHistorySelection(pair.historySelection); session.restoreAsyncRequests(pair.providers);
      if (pair.recovery) session.restoreRecovery(pair.recovery);
      const resumeDeferred = session.holdRemoteChanges(); session.restoreDeferredChanges(pair.deferred);
      // Validate retained rich data through Swift without applying any request.
      for (const item of pair.clipboard) if (item.clipboard) session.clipboardFromJSON(JSON.stringify(item.clipboard));
      const host = new ModernBrowserHost(session, pair.actorID, store, key, pair.revision);
      host.inputs = structuredClone([...pair.inputs]); host.clipboard = structuredClone([...pair.clipboard]);
      return { host, resumeDeferred };
    } catch (failure) { session.close(); throw failure; }
  }
  retainInput(target: ModernPasteTarget, text: string, reason: string, id = crypto.randomUUID()): void {
    const retained = this.inputs.filter(item => item.id !== id);
    if (retained.length >= 64 || retained.reduce((sum, draft) => sum + draft.text.length, text.length) > 16_000_000) throw new Error("Retained input capacity exceeded");
    this.inputs = [...retained, { id, target, text, reason: reason.slice(0, 1000) }];
  }
  retryInput(id: string): void {
    const input = this.inputs.find(item => item.id === id); if (!input || !this.active || this.readOnly) return;
    const result = this.session.execute({ command: "paste", target: input.target, arguments: { clipboard: this.session.clipboard(input.text), mode: "plainText" } });
    if (result.status === "applied" || result.status === "noop") this.inputs = this.inputs.filter(item => item.id !== id);
  }
  async runProvider(node: Parameters<SwiftModernSession["beginAsyncBlock"]>[0], provider: (target: ModernAsyncTarget) => Promise<ModernObject>): Promise<ModernAsyncRecord | undefined> {
    if (!this.active || this.readOnly) throw new Error("Inactive or read-only editor host");
    if (this.running.size >= 8 || JSON.stringify(this.session.exportAsyncRequests()).length + (this.running.size + 1) * 2_000_000 >= 16_000_000) throw new Error("Provider result capacity unavailable");
    const target = this.session.beginAsyncBlock(node, crypto.randomUUID()), generation = this.generation;
    this.running.add(target.requestID);
    try {
      await this.save();
      if (!this.active || this.readOnly || generation !== this.generation || !this.session.asyncRequests().some(item => item.target.requestID === target.requestID && item.status === "pending")) return;
      const metadata = structuredClone(await provider(target));
      this.unsaved.set(target.requestID, { target, metadata });
      this.session.retainAsyncResult(target, metadata);
      await this.save(); this.unsaved.delete(target.requestID);
      if (this.active && !this.readOnly && generation === this.generation) {
        this.session.execute({ command: "completeAsyncBlock", target, arguments: { metadata } }); await this.save();
      }
      return this.session.asyncRequests().find(record => record.target.requestID === target.requestID);
    } catch (error) {
      if (!this.unsaved.has(target.requestID) && this.session.asyncRequests().some(item => item.target.requestID === target.requestID && item.status === "pending")) {
        this.session.failAsyncBlock(target, String(error).slice(0, 1000));
        try { await this.save(); } catch { /* Core record stays visible for explicit persistence retry. */ }
      }
      throw error;
    } finally { this.running.delete(target.requestID); }
  }
  async retryResult(target: ModernAsyncTarget): Promise<void> {
    const metadata = this.unsaved.get(target.requestID)?.metadata ?? this.session.asyncRequests().find(item => item.target.requestID === target.requestID)?.result, generation = this.generation;
    if (!metadata || !this.active || this.readOnly) return;
    this.session.retainAsyncResult(target, metadata); await this.save(); this.unsaved.delete(target.requestID);
    if (!this.active || this.readOnly || generation !== this.generation) return;
    this.session.execute({ command: "completeAsyncBlock", target, arguments: { metadata } }); await this.save();
  }
  async cancelProvider(target: ModernAsyncTarget): Promise<void> { this.session.cancelAsyncBlock(target); await this.save(); }
  async copy(target: ModernDeleteTarget, cut = false, plainOnly = false): Promise<void> {
    const generation = this.generation, prepared = cut ? this.session.prepareCut(target) : undefined;
    const payload = prepared?.clipboard ?? this.session.copy(target);
    const escaped = payload.plainText.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
    const encoded = btoa(Array.from(new TextEncoder().encode(JSON.stringify(payload)), byte => String.fromCharCode(byte)).join(""));
    try {
      const item = new ClipboardItem({ "text/plain": new Blob([payload.plainText], { type: "text/plain" }),
        ...(!plainOnly ? { "text/html": new Blob([`<div data-seventwo-modern="${encoded}"><pre>${escaped}</pre></div>`], { type: "text/html" }) } : {}) });
      await navigator.clipboard.write([item]);
      if (prepared) this.session.finishCut(prepared, this.active && generation === this.generation);
    } catch (error) { if (prepared) this.session.finishCut(prepared, false); throw error; }
  }
  paste(target: ModernPasteTarget, data: DataTransfer, plainOnly = false): void {
    if (!this.active || this.readOnly) throw new Error("Inactive or read-only editor host");
    const html = data.getData("text/html"), plainText = data.getData("text/plain");
    const entry: ModernRetainedPaste = { id: crypto.randomUUID(), target: structuredClone(target), rawHTML: html, plainText, mode: plainOnly || !html ? "plainText" : "rich", reason: "awaitingPaste" };
    if (this.clipboard.length >= 64 || JSON.stringify([...this.clipboard, entry]).length > 64_000_000) throw new Error("Retained clipboard capacity exceeded");
    this.clipboard.push(entry); this.retryPaste(entry.id, plainOnly);
  }
  retryPaste(id: string, plainOnly = false): void {
    const entry = this.clipboard.find(item => item.id === id); if (!entry || !this.active || this.readOnly) return;
    try {
      let payload = entry.clipboard;
      if (plainOnly) payload = this.session.clipboard(entry.plainText ?? payload?.plainText ?? "", "multiline");
      else if (!payload) {
        if (entry.rawHTML && entry.mode !== "plainText") {
          const template = document.createElement("template"); template.innerHTML = entry.rawHTML;
          const internal = template.content.querySelector("[data-seventwo-modern]")?.getAttribute("data-seventwo-modern");
          if (internal) payload = this.session.clipboardFromJSON(new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(atob(internal), char => char.charCodeAt(0))));
          else {
            const blocks = parseClipboardHtml(entry.rawHTML);
            if (!blocks.length) throw new Error("Unsupported rich clipboard; choose Paste plain text to insert its visible text");
            payload = this.session.clipboardParts(blocks.map(block => ({ node: { kind: "block", value: block as unknown as ModernObject } })));
          }
        } else payload = this.session.clipboard(entry.plainText ?? "", "multiline");
      }
      // Preserve the original payload on any rejected or explicit fallback path.
      this.clipboard = this.clipboard.map(item => item.id === id && !plainOnly ? { ...item, clipboard: payload } : item);
      const result = this.session.execute({ command: "paste", target: entry.target, arguments: { clipboard: payload, mode: plainOnly ? "plainText" : entry.mode ?? "rich" } });
      if (result.status === "applied" || result.status === "noop") this.clipboard = this.clipboard.filter(item => item.id !== id);
      else throw new Error(result.reason ?? result.status);
    } catch (failure) {
      this.clipboard = this.clipboard.map(item => item.id === id ? { ...item, reason: String(failure).slice(0, 1000) } : item); throw failure;
    }
  }
}

function validateCheckpoint(pair: ModernBrowserCheckpoint): void {
  const size = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).length;
  if (pair.version !== 1 || typeof pair.revision !== "string" || typeof pair.actorID !== "string" || typeof pair.documentID !== "string" || typeof pair.epoch !== "string" ||
      !Array.isArray(pair.inputs) || !Array.isArray(pair.clipboard) || !Array.isArray(pair.deferred) || pair.inputs.length > 64 || pair.clipboard.length > 64 || pair.deferred.length > 64 ||
      size(pair.accepted) > 64_000_000 || size(pair.historySelection) > 16_000_000 || size(pair.providers) > 16_000_000 || size(pair.recovery) > 64_000_000 || size(pair.deferred) > 64_000_000 || size(pair.inputs) > 16_000_000 || size(pair.clipboard) > 64_000_000) throw new Error("Incompatible or oversized host checkpoint");
  const scoped = (value: { documentID: string; epoch: string }) => value.documentID === pair.documentID && value.epoch === pair.epoch;
  const target = (value: ModernPasteTarget) => {
    if (!value || (!!value.range === !!value.boundary) || (value.range && value.selection)) return false;
    const ranges = [...(value.range ? [value.range] : []), ...(value.selection?.ranges ?? [])];
    return (!value.boundary || scoped(value.boundary)) && (!value.selection?.nodes || scoped(value.selection.nodes)) && ranges.every(range => scoped(range.start) && scoped(range.end));
  };
  const identifiers = new Set<string>();
  for (const entry of [...pair.inputs, ...pair.clipboard]) {
    if (typeof entry.id !== "string" || identifiers.has(entry.id) || typeof entry.reason !== "string" || entry.reason.length > 1000 || !target(entry.target)) throw new Error("Invalid retained host request");
    identifiers.add(entry.id);
  }
  if (pair.inputs.some(item => typeof item.text !== "string") || pair.clipboard.some(item => (item.plainText !== undefined && typeof item.plainText !== "string") || (item.rawHTML !== undefined && typeof item.rawHTML !== "string") || (!item.clipboard && item.plainText === undefined))) throw new Error("Invalid retained clipboard or input");
}
