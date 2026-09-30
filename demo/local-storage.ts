import type { SwiftChangeBatch } from "../src/swift.js";

export interface LocalDraft { actor: string; snapshot: SwiftChangeBatch }

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
      const request = indexedDB.open("block-editor-local-lab", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("drafts");
      request.onsuccess = () => resolve(new DraftStore(request.result));
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("Close other editor tabs to open local storage."));
    });
  }
  async read(key: string): Promise<LocalDraft | undefined> {
    return new Promise((resolve, reject) => {
      const request = this.database.transaction("drafts").objectStore("drafts").get(key);
      request.onsuccess = () => resolve(request.result);
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
  async write(key: string, draft: LocalDraft): Promise<void> {
    return new Promise((resolve, reject) => {
      const transaction = this.database.transaction("drafts", "readwrite");
      transaction.objectStore("drafts").put(draft, key);
      transaction.oncomplete = () => resolve();
      transaction.onabort = () => reject(transaction.error ?? new Error("Local save was aborted."));
      transaction.onerror = () => reject(transaction.error);
    });
  }
  close() { this.database.close(); }
}
