import { startRelay } from "./server.ts";

const relay = await startRelay({
  executable: process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge",
  directory: process.env.DEMO_DATA ?? ".local-modern-demo", token: process.env.DEMO_TOKEN ?? "",
  port: Number(process.env.DEMO_PORT ?? 4319), modern: { epoch: "modern-reference-epoch", document: {
    format: "seventwo.block-editor.document", formatVersion: 1, documentID: "template", title: "Shared Help",
    appearance: { fontFamily: "sans", fontSize: "default", pageWidth: "readable" },
    blocks: [{ id: "p", type: "paragraph", content: [{ type: "text", text: "Write together locally. Each author keeps their own history." }] }],
  } },
});
console.log(`Modern local editor relay: ${relay.url}. Loopback reference only; protocol 7, format 1.`);
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, async () => {
  if (stopping) return; stopping = true; await relay.close(); process.exit(0);
});
