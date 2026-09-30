import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";

const destinations = process.argv.slice(2);
if (!destinations.length) throw new Error("Pass one or more iOS simulator xcodebuild destinations");
async function run(command: string[], env = process.env) {
  const child = Bun.spawn(command, { env, stdout: "inherit", stderr: "inherit" });
  if (await child.exited !== 0) throw new Error(`${command[0]} failed`);
}
await run(["xcodegen", "generate", "--spec", "Examples/AppleDemo/project.yml"]);
await run(["swift", "build", "--product", "editor-bridge"]);
const directory = await mkdtemp(join(tmpdir(), "editor-apple-ui-"));
const token = crypto.randomUUID();
const relay = await startRelay({ directory, executable: "./.build/debug/editor-bridge", token, port: 0 });
try {
  for (const destination of destinations) {
    await run(["xcodebuild", "-project", "Examples/AppleDemo/EditorLab.xcodeproj", "-scheme", "EditorLab-iOS",
      "-destination", destination, "-derivedDataPath", ".build/apple-demo", "-collect-test-diagnostics", "never",
      "CODE_SIGNING_ALLOWED=NO", "test"],
    { ...process.env, TEST_RUNNER_BLOCK_EDITOR_RELAY_URL: relay.url, TEST_RUNNER_BLOCK_EDITOR_RELAY_TOKEN: token });
  }
} finally { await relay.close(); await rm(directory, { recursive: true, force: true }); }
