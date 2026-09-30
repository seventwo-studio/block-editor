import { test, expect } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createCrdtState } from "./crdt.js";
import { Content } from "./schema.js";

const corpus = JSON.parse(readFileSync(new URL("../tests/BlockEditorCoreTests/Fixtures/documents.json", import.meta.url), "utf8"));
test("migration corpus reflects the canonical legacy schema and explicit future extensions", () => {
  for (const sample of corpus.valid) expect(Content.safeParse(sample.blocks).success, sample.name).toBe(sample.legacySchema);
  for (const sample of corpus.invalid) expect(Content.safeParse(sample.blocks).success, sample.name).toBe(sample.legacySchema ?? false);
});

test("legacy cutover preserves rich documents and source archives and rejects ambiguous clocks", () => {
  const dir = mkdtempSync(join(tmpdir(), "editor-migration-"));
  const input = join(dir, "operations.json");
  const output = join(dir, "document.json");
  const run = () => Bun.spawnSync([process.execPath, new URL("../scripts/migrate-legacy-crdt.ts", import.meta.url).pathname, input, output]);
  try {
    for (const sample of corpus.valid.filter((sample: { legacySchema: boolean }) => sample.legacySchema)) {
      const archive = JSON.stringify(createCrdtState("old", sample.blocks).operations);
      writeFileSync(input, archive);
      const result = run();
      expect(result.exitCode, result.stderr.toString()).toBe(0);
      expect(JSON.parse(readFileSync(output, "utf8")), sample.name).toEqual(sample.blocks);
      expect(readFileSync(input, "utf8")).toBe(archive);
      // An existing target is never overwritten.
      const before = readFileSync(output, "utf8");
      expect(run().exitCode).not.toBe(0);
      expect(readFileSync(output, "utf8")).toBe(before);
      rmSync(output);
    }
    const operations = createCrdtState("old", corpus.valid[0].blocks).operations.map(op => ({ ...op, clock: { siteId: "old", counter: 1 } }));
    const archive = JSON.stringify(operations);
    writeFileSync(input, archive);
    const result = run();
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("Ambiguous legacy clock");
    expect(existsSync(output)).toBe(false);
    expect(readFileSync(input, "utf8")).toBe(archive);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
