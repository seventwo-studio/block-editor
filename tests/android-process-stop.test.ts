import { test, expect } from "bun:test";
import { verifyAndroidProcessStop } from "../scripts/verify-android-process-stop";

const failure = (exitCode: number, output = "") => Object.assign(new Error("Original command failed"), { exitCode, output });
test("unknown API26 force-stop outcome succeeds only after absent-process readback", async () => {
  const calls: string[][] = [];
  const result = await verifyAndroidProcessStop(async args => {
    calls.push(args); if (args[1] === "am") throw failure(255); throw failure(1);
  }, "owned.test");
  expect(result).toEqual({ forceStopExit: 255, terminalConfirmed: true });
  expect(calls).toEqual([["shell", "am", "force-stop", "owned.test"], ["shell", "pidof", "owned.test"]]);
});
test("remaining process, unknown readback and other stop failures cannot pass", async () => {
  for (const readback of [async () => "1234", async () => { throw failure(255); }, async () => { throw failure(1, "permission denied"); }]) {
    await expect(verifyAndroidProcessStop(async args => { if (args[1] === "am") throw failure(255); return readback(); }, "owned.test")).rejects.toThrow();
  }
  await expect(verifyAndroidProcessStop(async () => { throw failure(1); }, "owned.test")).rejects.toThrow("Original command failed");
});
test("normal stop also confirms process absence", async () => {
  let count = 0;
  expect(await verifyAndroidProcessStop(async () => { count++; return ""; }, "owned.test")).toEqual({ forceStopExit: 0, terminalConfirmed: true });
  expect(count).toBe(2);
});
