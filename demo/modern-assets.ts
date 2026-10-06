/** Reference application storage, deliberately separate from the editor package.
 * A real Foliostrate host substitutes its own authorization and upload service. */
export async function exampleAssetStore(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("foliostrate-modern-example-assets", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("assets");
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
}
export async function storeExampleAsset(file: File): Promise<{ src: string; name: string; mimeType: string; size: number; width?: number; height?: number }> {
  if (file.size > 16_000_000) throw new Error("This local example accepts files up to 16 MB");
  const id = crypto.randomUUID(), db = await exampleAssetStore();
  try {
    await new Promise<void>((resolve, reject) => {
      const transaction = db.transaction("assets", "readwrite", { durability: "strict" }); transaction.objectStore("assets").add(file, id);
      transaction.oncomplete = () => resolve(); transaction.onabort = () => reject(transaction.error); transaction.onerror = () => reject(transaction.error);
    });
    const saved = await loadExampleAsset(`asset://${id}`);
    if (!saved || saved.size !== file.size || saved.type !== file.type) throw new Error("Asset readback mismatch");
    const result = { src: `asset://${id}`, name: file.name, mimeType: file.type, size: file.size };
    if (!file.type.startsWith("image/")) return result;
    const bitmap = await createImageBitmap(file);
    try { return { ...result, width: bitmap.width, height: bitmap.height }; } finally { bitmap.close(); }
  } finally { db.close(); }
}
export async function loadExampleAsset(source: string): Promise<Blob | undefined> {
  if (!/^asset:\/\/[0-9a-f-]{36}$/.test(source)) return;
  const db = await exampleAssetStore();
  try { return await new Promise((resolve, reject) => {
    const request = db.transaction("assets").objectStore("assets").get(source.slice(8)); request.onsuccess = () => resolve(request.result as Blob | undefined); request.onerror = () => reject(request.error);
  }); } finally { db.close(); }
}
