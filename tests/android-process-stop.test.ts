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

test("empty API26 pidof 255 requires a fresh successful complete process listing", async () => {
  const calls: string[][] = [];
  const result = await verifyAndroidProcessStop(async args => {
    calls.push(args);
    if (args[1] === "am") return "";
    if (args[1] === "pidof") throw failure(255);
    return "USER PID PPID VSZ RSS WCHAN ADDR S NAME\nroot 1 0 10 2 0 0 S init\nshell 27 1 10 2 0 0 S ps\n";
  }, "owned.test");
  expect(result).toEqual({ forceStopExit: 0, terminalConfirmed: true, processReadback: "ps" });
  expect(calls.at(-1)).toEqual(["shell", "ps", "-A"]);
});

test("process-list fallback rejects live package services, malformed rows and failed transport", async () => {
  const header = "USER PID PPID VSZ RSS WCHAN ADDR S NAME\n";
  for (const listing of ["", "error: device offline", header, header + "root 1 0 10 2 0 0 S owned.test",
    header + "root 1 0 10 2 0 0 S owned.test:provider", header + "root no-pid 0 10 2 0 0 S init",
    header + "root 1 0 10 2 0 0 S init extra", "USER PID NAME NAME\nroot 1 init init", "ERROR PID NAME\nroot 1 init"]) {
    await expect(verifyAndroidProcessStop(async args => {
      if (args[1] === "am") return "";
      if (args[1] === "pidof") throw failure(255);
      return listing;
    }, "owned.test")).rejects.toThrow();
  }
  await expect(verifyAndroidProcessStop(async args => {
    if (args[1] === "am") return "";
    throw failure(255);
  }, "owned.test")).rejects.toThrow("Original command failed");
});
