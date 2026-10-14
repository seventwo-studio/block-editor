import { test, expect } from "bun:test";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { modernRelayProcess } from "./helpers/modern-relay-process.ts";
import { NativeBridge } from "../demo/relay/bridge.ts";
import { encodeModernBridgeJSON } from "../src/swift-modern-json.ts";
import type { ModernDocument } from "../src/swift-modern.ts";

test("modern server rejects original wire/disk corruption and preserves signed zero through restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "relay-wire-")), documentID = "server-wire";
  const document: ModernDocument = { format: "seventwo.block-editor.document", formatVersion: 1, documentID, title: "Title",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" }, blocks: [], consumer: { zero: -0, keep: "東京😀" } };
  const headers = { "x-local-token": "modern-relay-test", "content-type": "application/json" }, epoch = "raw-server-epoch";
  let server = await modernRelayProcess(directory, { document, epoch });
  const bridge = new NativeBridge(resolve(process.env.BLOCK_EDITOR_BRIDGE ?? ".build/debug/editor-bridge"));
  const endpoint = () => `${server.url}/rooms/${documentID}`;
  try {
    const response = await fetch(endpoint(), { headers }), initial = await response.json();
    expect(Object.is(initial.baseline.consumer.zero, -0)).toBe(true);
    await bridge.call({ command: "restoreModern", session: "peer", actorID: "peer", snapshot: initial });
    const changed = await bridge.call({ command: "modernCommand", session: "peer", request: { documentID, epoch, command: "setAppearance",
      target: { document: { documentID } }, arguments: { field: "fontFamily", value: "serif" } } });
    expect(changed.status).toBe("applied");
    const body = encodeModernBridgeJSON({ actorID: "peer", batch: await bridge.call({ command: "modernChanges", session: "peer" }),
      state: (await bridge.call({ command: "modernSnapshot", session: "peer" })).syncState });
    const file = join(directory, `${documentID}.json`), before = await readFile(file);
    for (const malformed of [body.replace('"batch":', '"batch":{},"batch":'), body.replaceAll('"counter":1', '"counter":1.0000000000000001'),
      body.slice(0, -1) + ',"diagnostic":"\\ud800"}']) {
      const failed = await fetch(endpoint(), { method: "POST", headers, body: malformed });
      expect(failed.status).toBe(400); expect(await readFile(file)).toEqual(before);
    }
    const prefix = Buffer.from(body.slice(0, -1) + ',"diagnostic":"');
    expect((await fetch(endpoint(), { method: "POST", headers, body: Buffer.concat([prefix, Buffer.from([255]), Buffer.from('"}')]) })).status).toBe(400);
    expect(await readFile(file)).toEqual(before);
    const valid = await fetch(endpoint(), { method: "POST", headers, body }); expect(valid.status).toBe(200);
    const reply = await valid.json(); expect(Object.is(reply.batch.baseline.consumer.zero, -0)).toBe(true);
    const saved = await readFile(file); expect(saved.toString()).toContain('"zero":-0');
    await server.stop(); server = await modernRelayProcess(directory, { document, epoch });
    const reopened = await (await fetch(endpoint(), { headers })).json(); expect(Object.is(reopened.baseline.consumer.zero, -0)).toBe(true);
    const corrupt = saved.toString().replace('"baseline":', '"baseline":{},"baseline":'); await writeFile(file, corrupt);
    expect((await fetch(endpoint(), { headers })).status).toBe(400); expect(await readFile(file, "utf8")).toBe(corrupt);
  } finally { bridge.close(); await bridge.waitForExit(); await server.stop(); await rm(directory, { recursive: true, force: true }); }
});
