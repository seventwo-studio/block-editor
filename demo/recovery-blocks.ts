import { plainText } from "../src/model.js";
import type { InlineNode } from "../src/schema.js";
import type { SwiftMergeRecovery, SwiftNodeID } from "../src/swift.js";

export interface RecoveryBlock { identity: SwiftNodeID; key: string; label: string }
function key(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(key).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([name, item]) => `${JSON.stringify(name)}:${key(item)}`).join(",")}}`;
  return JSON.stringify(value);
}
/** Original root/toggle blocks, not an invalid merged preview. */
export function recoveryBlocks(recovery: SwiftMergeRecovery): RecoveryBlock[] {
  const blocks = new Map<string, { identity: SwiftNodeID; value: Record<string, any> }>();
  function register(value: Record<string, any>, identity: SwiftNodeID) {
    const pending = [{ value, identity }];
    while (pending.length) {
      const { value, identity } = pending.pop()!;
      blocks.set(key(identity), { value, identity });
      if (value.type !== "toggle") continue;
      for (const child of value.children ?? []) {
        const next: SwiftNodeID = "baseline" in identity
          ? { baseline: { ...identity.baseline, path: [...identity.baseline.path, "children", child.id] } }
          : { inserted: { ...identity.inserted, path: [...identity.inserted.path, "children", child.id] } };
        pending.push({ value: child, identity: next });
      }
    }
  }
  for (const block of (recovery.batch.baseline as { blocks: Record<string, any>[] }).blocks) {
    register(block, { baseline: { blockID: block.id, path: [] } });
  }
  // Engine proposals are canonical. Stable origin identity avoids ambiguous sibling labels.
  for (const change of recovery.batch.changes as { body: { edit?: { _0: { insertNode?: { value: Record<string, any>; identity: SwiftNodeID; collection: { owner?: SwiftNodeID; field: string } } }[] } } }[]) {
    for (const mutation of change.body.edit?._0 ?? []) {
      const inserted = mutation.insertNode;
      if (!inserted) continue;
      const owner = inserted.collection.owner && blocks.get(key(inserted.collection.owner))?.value;
      if (inserted.collection.field === "blocks" || (inserted.collection.field === "children" && owner?.type === "toggle")) register(inserted.value, inserted.identity);
    }
  }
  return [...blocks].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([key, { identity, value }]) => {
    const text = plainText((value[value.type === "toggle" ? "summary" : "content"] ?? []) as InlineNode[]);
    return { identity, key, label: `Original ${value.type ?? "block"}: ${[...(text || value.id || "Untitled")].slice(0, 60).join("")}` };
  });
}
