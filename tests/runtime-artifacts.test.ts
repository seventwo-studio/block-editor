import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";

const revision = "a".repeat(40);
const names = ["runtime-swift", "runtime-wasm", "runtime-android-api26-x86_64", "runtime-android-api35-x86_64", "runtime-android-api35-arm64-v8a"];
const artifacts = () => names.map((name, index) => ({
  id: index + 10, name, created_at: "2026-10-01T08:02:00Z", expired: false, size_in_bytes: 100,
  workflow_run: { id: 123, head_sha: revision },
}));
function select(values: ReturnType<typeof artifacts>, args: string[] = []) {
  return spawnSync("python3", ["scripts/select-runtime-artifacts.py", "123", revision, ...args], {
    input: JSON.stringify([{ artifacts: values }]), encoding: "utf8",
  });
}

test("a rerun selects newer metadata rather than artifact list or numeric ID order", () => {
  const values = artifacts();
  // Real rerun metadata can assign a lower numeric ID to a newer artifact.
  values.push({ ...values[4]!, id: 1, created_at: "2026-10-01T08:14:00Z" });
  const result = select(values.reverse(), ["--github-output"]);
  expect(result.status).toBe(0);
  expect(result.stdout.trim()).toBe("ids=10,11,12,13,1");
});

test("missing, expired and wrong-source latest artifacts cannot fall back to older evidence", () => {
  expect(select(artifacts().slice(1)).status).not.toBe(0);
  for (const patch of [
    { expired: true }, { size_in_bytes: 0 },
    { workflow_run: { id: 124, head_sha: revision } },
    { workflow_run: { id: 123, head_sha: "b".repeat(40) } },
  ]) {
    const values = artifacts();
    values.push({ ...values[4]!, ...patch, id: 1, created_at: "2026-10-01T08:14:00Z" });
    expect(select(values).status).not.toBe(0);
  }
});

test("ambiguous creation timestamps reject instead of choosing arbitrarily", () => {
  const values = artifacts();
  values.push({ ...values[4]!, id: 1 });
  expect(select(values).status).not.toBe(0);
});
