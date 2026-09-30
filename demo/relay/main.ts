import { startRelay } from "./server.ts";

const relay = await startRelay({
  executable: process.env.BLOCK_EDITOR_BRIDGE ?? "./.build/debug/editor-bridge",
  directory: process.env.DEMO_DATA ?? ".local-demo",
  token: process.env.DEMO_TOKEN ?? "",
  port: Number(process.env.DEMO_PORT ?? 4319),
});
console.log(`Local editor relay: ${relay.url}. No public listener or production backend.`);
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, async () => { await relay.close(); process.exit(0); });
