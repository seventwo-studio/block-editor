import { startRelay } from "../demo/relay/server.ts";

// Test-only subprocess: a restart discards all relay/bridge memory while keeping
// the supplied directory. The reference relay remains loopback-only.
const options = JSON.parse(process.env.RELAY_PROCESS_OPTIONS ?? "{}");
const relay = await startRelay(options);
console.log(JSON.stringify({ url: relay.url, pid: process.pid }));
let stopping = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, async () => {
  if (stopping) return;
  stopping = true;
  await relay.close();
  process.exit(0);
});
