import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";

// Each destination runs native tests against one isolated, loopback-only relay.
const destinations = process.argv.slice(2);
if (!destinations.length) throw new Error("Pass one or more xcodebuild destinations, e.g. 'platform=iOS Simulator,name=iPhone 18 Pro'");
const build = Bun.spawn(["swift", "build", "--product", "editor-bridge"], { stdout: "inherit", stderr: "inherit" });
if (await build.exited !== 0) throw new Error("The native relay engine failed to build");
const directory = await mkdtemp(join(tmpdir(), "editor-apple-relay-"));
const token = crypto.randomUUID();
const relay = await startRelay({ directory, executable: "./.build/debug/editor-bridge", token, port: 0 });
try {
  for (const destination of destinations) {
    console.log(`Verifying Apple relay integration on ${destination}`);
    const test = Bun.spawn(["xcodebuild", "-scheme", "BlockEditor-Package", "-destination", destination,
      "-derivedDataPath", ".build/apple-relay-tests", "-only-testing:BlockEditorLocalDemoTests",
      "CODE_SIGNING_ALLOWED=NO", "test"], {
      env: { ...process.env, TEST_RUNNER_BLOCK_EDITOR_RELAY_URL: relay.url, TEST_RUNNER_BLOCK_EDITOR_RELAY_TOKEN: token },
      stdout: "inherit", stderr: "inherit",
    });
    if (await test.exited !== 0) throw new Error(`Apple relay integration failed on ${destination}`);
  }
} finally { await relay.close(); await rm(directory, { recursive: true, force: true }); }
