import { decodeCrdtState } from "../src/crdt.ts";
import { Content } from "../src/schema.ts";

// Run once at a coordinated cutover. Keep the source archive; do not overwrite it.
const [input, output] = process.argv.slice(2);
if (!input || !output || input === output) {
  throw new Error("Usage: bun scripts/migrate-legacy-crdt.ts old-operations.json new-document.json");
}
if (await Bun.file(output).exists()) throw new Error("Output already exists");
const payload = new Uint8Array(await Bun.file(input).arrayBuffer());
const operations = JSON.parse(new TextDecoder().decode(payload));
if (!Array.isArray(operations)) throw new Error("Expected legacy operation array");
const keys = new Map<string, string>();
const clockOwners = new Map<string, string>();
for (const op of operations) {
  if (!op || !["insert", "update", "move", "delete"].includes(op.type) ||
      typeof op.id !== "string" || !op.id || typeof op.clock?.siteId !== "string" ||
      !Number.isSafeInteger(op.clock?.counter) || op.clock.counter < 0) {
    throw new Error("Invalid legacy operation");
  }
  if (op.type === "insert" || op.type === "update") Content.parse([op.block]);
  if ((op.type === "insert" || op.type === "move") && !Number.isSafeInteger(op.index)) throw new Error("Invalid index");
  const key = `${op.clock.siteId}:${op.clock.counter}:${op.type}:${op.id}`;
  const encoded = JSON.stringify(op);
  if (keys.has(key) && keys.get(key) !== encoded) throw new Error("Conflicting legacy operation identity");
  keys.set(key, encoded);
  const clock = `${op.clock.siteId}:${op.clock.counter}`;
  // Clock-zero imports legitimately contain multiple initial blocks. Preserve original
  // archive order there; ambiguous later same-clock operations need manual reconciliation.
  if (op.clock.counter > 0 && clockOwners.has(clock) && clockOwners.get(clock) !== key) {
    throw new Error("Ambiguous legacy clock; reconcile the source before migration");
  }
  clockOwners.set(clock, key);
}
const document = decodeCrdtState("migration", payload).blocks;
Content.parse(document);
await Bun.write(output, JSON.stringify(document, null, 2));
console.log(`Exported ${document.length} blocks. Keep the original archive and start a new collaboration document ID.`);
