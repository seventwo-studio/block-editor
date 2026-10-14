import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { SwiftMergeRecoveryError } from "../../src/swift.ts";
import { SwiftModernRecoveryError } from "../../src/swift-modern.ts";
import { encodeModernBridgeJSON } from "../../src/swift-modern-json.ts";

/** The demo server validates and materializes changes in the actual Swift engine. */
export class NativeBridge {
  private child;
  private pending: Array<{ resolve: (value: any) => void; reject: (error: Error) => void }> = [];
  private failure: Error | undefined;
  private exited: Promise<number | null>;
  constructor(executable: string) {
    this.child = spawn(executable, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.exited = new Promise(resolve => { this.child.once("exit", resolve); this.child.once("error", () => resolve(null)); });
    const fail = (error: Error) => {
      this.failure = error;
      for (const request of this.pending.splice(0)) request.reject(error);
    };
    this.child.on("error", fail);
    this.child.stdin.on("error", fail);
    this.child.on("exit", () => fail(new Error("Swift bridge stopped")));
    createInterface({ input: this.child.stdout }).on("line", line => {
      const request = this.pending.shift();
      if (!request) { fail(new Error("Unexpected bridge output")); return; }
      try {
        const response = JSON.parse(line);
        if (!response.ok) request.reject(response.error === "modernRecoveryRequired" && response.recovery
          ? new SwiftModernRecoveryError(response.recovery) : response.error === "mergeRecoveryRequired" && response.recovery
          ? new SwiftMergeRecoveryError(response.recovery) : new Error(response.error));
        else request.resolve(response.value);
      } catch (error) { request.reject(error as Error); }
    });
  }
  call(request: Record<string, unknown>): Promise<any> {
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      const modern = typeof request.command === "string" && (request.command.startsWith("modern") || ["createModern", "restoreModern", "cutoverToModern"].includes(request.command));
      this.child.stdin.write((modern ? encodeModernBridgeJSON(request) : JSON.stringify(request)) + "\n");
    });
  }
  inspectJSON(bytes: Uint8Array): Promise<any> {
    return this.call({ command: "modernInspectJSON", encoded: new TextDecoder("utf-8", { fatal: true }).decode(bytes) });
  }
  close() { this.child.kill(); }
  waitForExit(): Promise<number | null> { return this.exited; }
  get processID(): number | undefined { return this.child.pid; }
}
