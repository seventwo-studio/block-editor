import { test, expect } from "bun:test";
import { encodeModernBridgeJSON } from "../src/swift-modern-json.js";
test("modern encoding retains signed zero, Unicode, aliases and deep metadata", () => {
  const shared = { zero: -0, text: "東京😀", optional: undefined };
  const value = { a: shared, b: shared, values: [-0, 0, undefined, "-0", '"zero":0'] };
  const encoded = encodeModernBridgeJSON(value), decoded = JSON.parse(encoded);
  expect(Object.is(decoded.a.zero, -0)).toBe(true); expect(Object.is(decoded.b.zero, -0)).toBe(true);
  expect(Object.is(decoded.values[0], -0)).toBe(true); expect(Object.is(decoded.values[1], 0)).toBe(true);
  expect(decoded.values.slice(2)).toEqual([null, "-0", '"zero":0']); expect(decoded.a.text).toBe("東京😀"); expect("optional" in decoded.a).toBe(false);
  const deep: Record<string, unknown> = {}; let current = deep;
  for (let index = 0; index < 1000; index++) current = current.child = {} as Record<string, unknown>;
  current.value = -0; expect(encodeModernBridgeJSON(deep).endsWith('"value":-0' + "}".repeat(1001))).toBe(true);
});
test("unsupported modern values and cycles reject without calling callbacks", () => {
  const cycle: Record<string, unknown> = {}; cycle.self = cycle;
  expect(() => encodeModernBridgeJSON(cycle)).toThrow(); expect(() => encodeModernBridgeJSON({ value: NaN })).toThrow();
  expect(() => encodeModernBridgeJSON({ value: Infinity })).toThrow(); expect(() => encodeModernBridgeJSON({ value: 1n })).toThrow();
  expect(() => encodeModernBridgeJSON({ value: new Date() })).toThrow();
  let called = false; const result = JSON.parse(encodeModernBridgeJSON({ toJSON: () => { called = true; return "replace"; }, retained: "original" }));
  expect(called).toBe(false); expect(result).toEqual({ retained: "original" });
});
