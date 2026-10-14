import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { readAndroidRelayProof } from "../scripts/read-android-relay-proof.ts";

const remote = "files/modern-process-12345678-1234-1234-1234-123456789abc-offline.json";
const original = '{"passed":true,"phase":"offline","text":"世界😀é"}\n';
const digest = (raw = original) => `${createHash("sha256").update(raw).digest("hex")}  ${remote}\n`;
const transportFailure = (exitCode: number, output: string) => Object.assign(new Error("ADB failed"), { exitCode, output });
async function scenario(values: Array<string | Error>, failed = false) {
  const directory = await mkdtemp(join(tmpdir(), "editor-relay-read-")), destination = join(directory, "proof.json");
  const commands: string[][] = [], waits: number[] = [];
  try {
    const run = readAndroidRelayProof(remote, destination, async parts => {
      commands.push(parts); const value = values.shift(); if (value instanceof Error) throw value;
      if (value === undefined) throw new Error("Unexpected extra command"); return value;
    }, async ms => { waits.push(ms); });
    if (failed) await expect(run).rejects.toThrow(); else expect(await run).toBe(original);
    const receipt = JSON.parse(await readFile(`${destination}.readback.json`, "utf8"));
    return { receipt, commands, waits, saved: await readFile(destination, "utf8").catch(() => undefined) };
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test("complete proof preserves literal Unicode and exact remote digest", async () => {
  const result = await scenario([digest(), original]);
  expect(result.saved).toBe(original); expect(result.receipt.passed).toBe(true); expect(result.waits).toEqual([]);
  expect(result.commands[1]?.[0]).toBe("exec-out");
});
test("empty exit255 read retries the immutable file without instrumentation", async () => {
  const result = await scenario([digest(), transportFailure(255, ""), digest(), original]);
  expect(result.receipt.attempts.map((a: { passed: boolean }) => a.passed)).toEqual([false, true]);
  expect(result.waits).toEqual([2000]); expect(result.commands.every(parts => !parts.includes("instrument"))).toBe(true);
});
test("exit-zero truncated bytes require exact hash readback before publication", async () => {
  const result = await scenario([digest(), original.slice(0, -5), digest(), original]);
  expect(result.waits).toEqual([2000]); expect(result.receipt.attempts[0].actualSHA256).not.toBe(result.receipt.attempts[0].expectedSHA256);
  expect(result.saved).toBe(original);
});
test("three total empty transport failures exhaust the read budget", async () => {
  const failure = transportFailure(255, ""); const result = await scenario([failure, failure, failure], true);
  expect(result.receipt.attempts).toHaveLength(3); expect(result.waits).toEqual([2000, 5000]); expect(result.saved).toBeUndefined();
});
test("denied, missing, timeout and nonempty exit255 fail without retries", async () => {
  for (const error of [transportFailure(1, "Permission denied"), transportFailure(1, "No such file"), new Error("timed out"), transportFailure(255, "offline")]) {
    const result = await scenario([error], true); expect(result.waits).toEqual([]); expect(result.commands).toHaveLength(1);
    expect(result.saved).toBeUndefined(); expect(result.receipt.passed).toBe(false);
  }
});
test("changed immutable digest cannot replace the original after an incomplete read", async () => {
  const result = await scenario([digest(), "", digest("changed")], true);
  expect(result.commands).toHaveLength(3); expect(result.saved).toBeUndefined(); expect(result.receipt.attempts[1].failure).toContain("changed");
});
test("invalid digest or complete malformed JSON fails without accepting content", async () => {
  for (const values of [["malformed digest"], [digest("{"), "{"]]) {
    const result = await scenario(values, true); expect(result.waits).toEqual([]); expect(result.saved).toBeUndefined();
  }
});
