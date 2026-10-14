import { createHash } from "node:crypto";
import { writeFile, rename } from "node:fs/promises";

/** Retry an immutable, uniquely named proof read, never instrumentation.
 * Empty exit-255 transport outcomes and incomplete bytes are the only retries. */
export async function readAndroidRelayProof(remote: string, destination: string,
  command: (parts: string[]) => Promise<string>, sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))): Promise<string> {
  if (!/^files\/modern-process-[0-9a-f-]{36}-(seed|offline|rejoin|undo|redo)\.json$/.test(remote)) throw new Error("Not an owned relay proof path");
  const attempts: Array<Record<string, unknown>> = [];
  let pinned: string | undefined;
  for (let number = 1; number <= 3; number++) {
    const record: Record<string, unknown> = { attempt: number, passed: false, remote };
    attempts.push(record);
    let retry = false;
    try {
      const digest = await command(["shell", "run-as", "studio.seventwo.blockeditor.test", "sha256sum", remote]);
      const escaped = remote.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const match = new RegExp(`^([0-9a-f]{64})[ \\t]+[ *]?${escaped}\\s*$`).exec(digest);
      if (!match) throw new Error("Invalid remote relay proof digest");
      if (pinned && match[1] !== pinned) throw new Error("Immutable relay proof changed between attempts");
      pinned = match[1]; record.expectedSHA256 = pinned;
      const raw = await command(["exec-out", "run-as", "studio.seventwo.blockeditor.test", "cat", remote]);
      const partial = `${destination}.attempt-${number}.partial`;
      await writeFile(partial, raw);
      const actual = createHash("sha256").update(raw).digest("hex");
      record.actualSHA256 = actual; record.byteCount = Buffer.byteLength(raw);
      if (actual !== pinned) { retry = true; throw new Error("Relay proof readback bytes differ from remote file"); }
      JSON.parse(raw);
      await rename(partial, destination); record.passed = true;
      return raw;
    } catch (failure) {
      const error = failure as { exitCode?: number; output?: string };
      record.failure = String(failure);
      if (error.exitCode !== undefined) {
        record.exitCode = error.exitCode; record.outputBytes = Buffer.byteLength(error.output ?? "");
        await writeFile(`${destination}.attempt-${number}.output`, error.output ?? "");
        retry = error.exitCode === 255 && error.output === "";
      }
      if (!retry || number === 3) throw failure;
    } finally {
      await writeFile(`${destination}.readback.json`, JSON.stringify({ passed: record.passed, attempts }, null, 2) + "\n");
    }
    await sleep(number === 1 ? 2000 : 5000);
  }
  throw new Error("Relay proof readback exhausted");
}
