/** Typed modern requests retain signed zero and ordinary optional/sparse
 * fields. Iterative encoding never invokes callbacks or strips finite input. */
export function encodeModernBridgeJSON(value: Record<string, unknown>): string {
  type Frame = { value: unknown; array?: boolean } | { token: string; close?: object };
  const pending: Frame[] = [{ value }], active = new Set<object>(), tokens: string[] = [];
  while (pending.length) {
    const frame = pending.pop()!;
    if ("token" in frame) { tokens.push(frame.token); if (frame.close) active.delete(frame.close); continue; }
    const item = frame.value;
    if (item === null) { tokens.push("null"); continue; }
    if (typeof item === "string" || typeof item === "boolean") { tokens.push(JSON.stringify(item)); continue; }
    if (typeof item === "number") {
      if (!Number.isFinite(item)) throw new TypeError("Modern JSON requires finite numbers");
      tokens.push(Object.is(item, -0) ? "-0" : JSON.stringify(item)); continue;
    }
    if (item === undefined || typeof item === "function" || typeof item === "symbol") {
      if (frame.array) { tokens.push("null"); continue; }
      throw new TypeError("Invalid modern JSON value");
    }
    if (typeof item !== "object") throw new TypeError("Invalid modern JSON value");
    if (active.has(item)) throw new TypeError("Cyclic modern JSON");
    active.add(item);
    if (Array.isArray(item)) {
      tokens.push("["); pending.push({ token: "]", close: item });
      for (let index = item.length - 1; index >= 0; index--) {
        pending.push({ value: item[index], array: true }); if (index > 0) pending.push({ token: "," });
      }
    } else {
      const prototype = Object.getPrototypeOf(item);
      if (prototype !== Object.prototype && prototype !== null) throw new TypeError("Modern JSON requires plain objects");
      const entries = Object.entries(item).filter(([, child]) => child !== undefined && typeof child !== "function" && typeof child !== "symbol");
      tokens.push("{"); pending.push({ token: "}", close: item });
      for (let index = entries.length - 1; index >= 0; index--) {
        const [key, child] = entries[index]; pending.push({ value: child }); pending.push({ token: ":" }); pending.push({ token: JSON.stringify(key) });
        if (index > 0) pending.push({ token: "," });
      }
    }
  }
  return tokens.join("");
}
