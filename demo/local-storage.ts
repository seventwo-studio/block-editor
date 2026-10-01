import type { SwiftChangeBatch, SwiftMergeRecovery } from "../src/swift.js";

export interface LocalDraft {
  version: 2;
  actor: string;
  snapshot: SwiftChangeBatch;
  pending: SwiftMergeRecovery | null;
}

export interface RecoveryArchive {
  kind: "block-editor-recovery";
  version: 1;
  snapshot: SwiftChangeBatch;
  pending: SwiftMergeRecovery | null;
}

/** Validate the host envelope here; the engine validates both histories before storage. */
export function decodeArchive(value: unknown): RecoveryArchive {
  if (!object(value) || value.kind !== "block-editor-recovery" || value.version !== 1 || !Object.hasOwn(value, "pending"))
    throw new Error("Unsupported recovery archive. The file and saved drafts were preserved.");
  const draft = decodeDraft({ version: 2, actor: "archive-validation", snapshot: value.snapshot, pending: value.pending });
  return { kind: "block-editor-recovery", version: 1, snapshot: draft.snapshot, pending: draft.pending };
}

export async function readArchive(file: File): Promise<RecoveryArchive> {
  // Two bounded engine histories plus their host envelope. Check before allocating.
  if (file.size > 130_000_000) throw new Error("Recovery archive exceeds the import limit. Keep the file for a supported transport or cutover.");
  // FileReader also supports file-picker input on WebKit hosts where File.text fails.
  const text = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error ?? new Error("Unable to read the recovery archive."));
    reader.onabort = () => reject(new Error("Recovery archive reading was cancelled."));
    reader.readAsText(file);
  });
  return decodeArchive(JSON.parse(text));
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function batch(value: unknown): value is SwiftChangeBatch {
  return object(value) && (value.version === 1 || value.version === 2) && typeof value.documentID === "string"
    && object(value.baseline) && Array.isArray(value.changes);
}
/** Decode before restoring or writing; an unreadable draft stays untouched. */
export function decodeDraft(value: unknown): LocalDraft {
  if (!object(value) || (value.version !== undefined && value.version !== 2)) throw new Error("Unsupported local draft version; the stored draft was preserved.");
  if (typeof value.actor !== "string" || !value.actor || !batch(value.snapshot)) throw new Error("Invalid local draft; the stored draft was preserved.");
  const pending = value.pending ?? null;
  if (pending !== null && (!object(pending) || !["identityConflict", "schemaConstraint"].includes(String(pending.reason))
    || !batch(pending.batch) || pending.batch.version !== 2 || value.snapshot.version !== 2
    || pending.batch.documentID !== value.snapshot.documentID)) throw new Error("Invalid or incompatible recovery proposal; the stored draft was preserved.");
  return { version: 2, actor: value.actor, snapshot: value.snapshot, pending: pending as SwiftMergeRecovery | null };
}

/** One tab owns each saved writer identity, including across reloads. */
export async function claimDraft(key: string): Promise<() => void> {
  if (!navigator.locks) throw new Error("This browser cannot safely resume a local writer.");
  return new Promise((resolve, reject) => {
    void navigator.locks.request(`block-editor:${key}`, { ifAvailable: true }, async lock => {
      if (!lock) { reject(new Error("This draft is already open in another tab. Close that tab before reopening.")); return; }
      await new Promise<void>(release => resolve(release));
    }).catch(reject);
  });
}

export class DraftStore {
  private constructor(private database: IDBDatabase) {}
  static async open(): Promise<DraftStore> {
    return new Promise((resolve, reject) => {
      // Old bundles opening version 1 fail instead of overwriting pending recovery.
      const request = indexedDB.open("block-editor-local-lab", 2);
      let abandoned = false;
      request.onupgradeneeded = () => { if (!request.result.objectStoreNames.contains("drafts")) request.result.createObjectStore("drafts"); };
      request.onsuccess = () => {
        if (abandoned) { request.result.close(); return; }
        request.result.onversionchange = () => request.result.close();
        resolve(new DraftStore(request.result));
      };
      request.onerror = () => reject(request.error);
      request.onblocked = () => { abandoned = true; reject(new Error("Close other editor tabs to upgrade local storage.")); };
    });
  }
  async read(key: string): Promise<LocalDraft | undefined> {
    return new Promise((resolve, reject) => {
      const request = this.database.transaction("drafts").objectStore("drafts").get(key);
      request.onsuccess = () => { try { resolve(request.result === undefined ? undefined : decodeDraft(request.result)); } catch (error) { reject(error); } };
      request.onerror = () => reject(request.error);
    });
  }
  async clients(room: string): Promise<string[]> {
    return new Promise((resolve, reject) => {
      const request = this.database.transaction("drafts").objectStore("drafts").getAllKeys();
      request.onsuccess = () => resolve(request.result.filter((key): key is string => typeof key === "string" && key.startsWith(`${room}:`)).map(key => key.slice(room.length + 1)));
      request.onerror = () => reject(request.error);
    });
  }
  async write(key: string, draft: LocalDraft, create = false): Promise<void> {
    decodeDraft(draft);
    return new Promise((resolve, reject) => {
      const transaction = this.database.transaction("drafts", "readwrite");
      const drafts = transaction.objectStore("drafts");
      if (create) drafts.add(draft, key); else drafts.put(draft, key);
      transaction.oncomplete = () => resolve();
      transaction.onabort = () => reject(transaction.error ?? new Error("Local save was aborted."));
      transaction.onerror = () => reject(transaction.error);
    });
  }
  close() { this.database.close(); }
}
