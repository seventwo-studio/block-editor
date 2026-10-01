import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay } from "../demo/relay/server.ts";

const sdk = process.env.ANDROID_HOME;
if (!sdk) throw new Error("Set ANDROID_HOME to the existing Android SDK");
const serial = process.env.ANDROID_SERIAL;
if (!serial) throw new Error("Set ANDROID_SERIAL to the test emulator");
const gradle = process.env.GRADLE_BIN ?? "gradle";
async function run(command: string[], cwd?: string): Promise<string> {
  const child = Bun.spawn(command, { cwd, stdout: "pipe", stderr: "inherit" });
  const result = await new Response(child.stdout).text();
  process.stdout.write(result);
  if (await child.exited !== 0) throw new Error(`${command[0]} failed`);
  return result;
}
await run(["swift", "build", "--product", "editor-bridge"]);
await run([gradle, ":demo:assembleDebug", ":demo:assembleDebugAndroidTest", ":editor:assembleDebugAndroidTest"], "android");
const directory = await mkdtemp(join(tmpdir(), "editor-android-recovery-"));
const token = crypto.randomUUID();
const relay = await startRelay({ directory, executable: "./.build/debug/editor-bridge", token, port: 0 });
let recovery: Awaited<ReturnType<typeof startRelay>> | undefined;
try {
  recovery = await startRelay({ directory: join(directory, "recovery"), executable: "./.build/debug/editor-bridge", token,
    port: 0, blocks: [], collaborationVersion: 2 });
  const adb = [join(sdk, "platform-tools/adb"), "-s", serial];
  await run([...adb, "install", "-r", "android/demo/build/outputs/apk/debug/demo-debug.apk"]);
  await run([...adb, "install", "-r", "android/demo/build/outputs/apk/androidTest/debug/demo-debug-androidTest.apk"]);
  // Reset only our isolated library test APK. A legacy-target warning from an
  // older test installation can otherwise cover the demo even after an update.
  const installed = await run([...adb, "shell", "pm", "list", "packages", "studio.seventwo.blockeditor.test"]);
  if (installed.split(/\r?\n/).includes("package:studio.seventwo.blockeditor.test"))
    await run([...adb, "uninstall", "studio.seventwo.blockeditor.test"]);
  await run([...adb, "install", "-r", "android/editor/build/outputs/apk/androidTest/debug/editor-debug-androidTest.apk"]);
  const result = await run([...adb, "shell", "am", "instrument", "-w", "-r",
    "-e", "relayUrl", relay.url.replace("127.0.0.1", "10.0.2.2"),
    "-e", "recoveryRelayUrl", recovery.url.replace("127.0.0.1", "10.0.2.2"), "-e", "relayToken", token,
    "studio.seventwo.blockeditor.demo.test/androidx.test.runner.AndroidJUnitRunner"]);
  if (!/OK \(\d+ tests?\)/.test(result) || /FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed/.test(result))
    throw new Error("Android instrumentation did not pass");
  const library = await run([...adb, "shell", "am", "instrument", "-w", "-r",
    "studio.seventwo.blockeditor.test/androidx.test.runner.AndroidJUnitRunner"]);
  if (!/OK \(\d+ tests?\)/.test(library) || /FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed/.test(library))
    throw new Error("Packaged JNI/input instrumentation did not pass");
  const recoveryRun = `android-restart-${crypto.randomUUID()}`;
  const recoveryURL = recovery.url;
  const recoveryPort = Number(new URL(recoveryURL).port);
  const phase = async (name: string) => {
    const output = await run([...adb, "shell", "am", "instrument", "-w", "-r",
      "-e", "class", "studio.seventwo.blockeditor.demo.RecoveryRestartUiTest#processRestartPhase",
      "-e", "recoveryPhase", name, "-e", "recoveryRun", recoveryRun,
      "-e", "recoveryRelayUrl", recoveryURL.replace("127.0.0.1", "10.0.2.2"), "-e", "relayToken", token,
      "studio.seventwo.blockeditor.demo.test/androidx.test.runner.AndroidJUnitRunner"]);
    if (!/OK \(1 test\)/.test(output) || /FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_STATUS_CODE: -[234]/.test(output))
      throw new Error(`Android recovery process phase ${name} did not pass`);
  };
  await phase("prepare");
  await run([...adb, "shell", "am", "force-stop", "studio.seventwo.blockeditor.demo"]);
  await recovery.close(); recovery = undefined;
  await phase("repair"); // The relay is stopped; restoration and repair must work offline.
  await run([...adb, "shell", "am", "force-stop", "studio.seventwo.blockeditor.demo"]);
  recovery = await startRelay({ directory: join(directory, "recovery"), executable: "./.build/debug/editor-bridge", token,
    port: recoveryPort, blocks: [], collaborationVersion: 2 });
  await phase("verify");
} finally {
  try { await recovery?.close(); }
  finally { try { await relay.close(); } finally { await rm(directory, { recursive: true, force: true }); } }
}
