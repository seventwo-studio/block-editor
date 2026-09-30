import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

/** The demo server validates and materializes changes in the actual Swift engine. */
export class NativeBridge {
  private child;
  private pending: Array<{ resolve: (value: any) => void; reject: (error: Error) => void }> = [];
  private failure: Error | undefined;
  constructor(executable: string) {
    this.child = spawn(executable, [], { stdio: ["pipe", "pipe", "inherit"] });
    const fail = (error: Error) => {
      this.failure = error;
      for (const request of this.pending.splice(0)) request.reject(error);
    };
    this.child.on("error", fail);
    this.child.on("exit", () => fail(new Error("Swift bridge stopped")));
    createInterface({ input: this.child.stdout }).on("line", line => {
      const request = this.pending.shift();
      if (!request) { fail(new Error("Unexpected bridge output")); return; }
      try {
        const response = JSON.parse(line);
        if (!response.ok) request.reject(new Error(response.error));
        else request.resolve(response.value);
      } catch (error) { request.reject(error as Error); }
    });
  }
  call(request: Record<string, unknown>): Promise<any> {
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.child.stdin.write(JSON.stringify(request) + "\n");
    });
  }
  close() { this.child.kill(); }
}
