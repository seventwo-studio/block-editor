import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fixtureNames, runFixture, canonical } from './compatibility.mjs';

const binary = resolve(process.argv[2] ?? '.build/debug/editor-bridge');
const output = resolve(process.argv[3] ?? 'test-results/compatibility/native.json');
mkdirSync(dirname(output), { recursive: true });
const report = { version: 1, fixtureHashes: {}, fixtures: {} };
for (const name of fixtureNames) {
  const source = readFileSync(`tests/BlockEditorCoreTests/Fixtures/${name}.json`);
  report.fixtureHashes[name] = createHash('sha256').update(source).digest('hex');
  const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const terminated = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`Bridge exited ${code ?? signal}`)));
  });
  // Attach before issuing requests, including failures before the first response.
  terminated.catch(() => {});
  const call = async input => {
    child.stdin.write(`${JSON.stringify(input)}\n`);
    const result = await lines.next();
    if (result.done) throw new Error(`${name}: bridge terminated before its response`);
    return JSON.parse(result.value);
  };
  try {
    report.fixtures[name] = await runFixture(name, JSON.parse(source), call);
    console.log(`${name}: ${report.fixtures[name].responses.length} runtime responses verified`);
  } finally {
    child.stdin.end();
    await terminated;
    writeFileSync(output, `${JSON.stringify(canonical(report), null, 2)}\n`);
  }
}
