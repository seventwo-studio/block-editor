import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { runWritingResourceCase, validateResourceSpec } from './writing-resource.mjs';
const binary = resolve(process.argv[2] ?? '.build/debug/editor-bridge');
const output = resolve(process.argv[3] ?? 'test-results/resource'); mkdirSync(output, { recursive: true });
const source = readFileSync('benchmarks/resources-writing.json'), spec = JSON.parse(source); validateResourceSpec(spec);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const metadata = { version: 1, kind: 'compact-production-resource-proof', runtime: 'native', specSHA256: hash(source),
  source: { commit: git('rev-parse', 'HEAD'), tree: git('rev-parse', 'HEAD^{tree}'), dirty: !!git('status', '--porcelain', '--untracked-files=all') },
  artifacts: [{ name: 'editor-bridge', role: 'debug-bridge', rawBytes: statSync(binary).size, sha256: hash(readFileSync(binary)) }],
  boundary: 'Actual editor-bridge process JSON calls; generated real production limits; host/UI/rendering acceptance excluded' };
for (const version of spec.protocols) for (const caseName of spec.cases) {
  const file = `${output}/resource-writing-native-v${version}-${caseName}.json`;
  const report = { ...metadata, protocol: version, case: caseName, complete: false };
  const publish = () => writeFileSync(file, `${JSON.stringify(report, null, 2)}\n`); publish();
  const child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  let diagnostic = ''; child.stderr.setEncoding('utf8'); child.stderr.on('data', value => { diagnostic += value; });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const terminated = new Promise((resolve, reject) => { child.on('error', reject); child.on('close', (code, signal) => code === 0 ? resolve() : reject(new Error(`Resource child exited ${code ?? signal}`))); }); terminated.catch(() => {});
  const timeout = setTimeout(() => { child.kill('SIGTERM'); report.error = 'Real resource case exceeded900s watchdog'; }, 900_000);
  let failure;
  try {
    report.proof = await runWritingResourceCase(spec, version, caseName, async request => {
      const packet = `${JSON.stringify(request)}\n`;
      await new Promise((resolve, reject) => child.stdin.write(packet, error => error ? reject(error) : resolve()));
      const response = await lines.next(); if (response.done) throw new Error('Resource child ended before response');
      return JSON.parse(response.value);
    }, async bytes => hash(bytes));
    child.stdin.end(); await terminated; if (report.error) throw new Error(report.error); report.complete = true;
  } catch (error) { failure = error; report.error = String(error); child.stdin.end(); child.kill('SIGTERM'); }
  finally {
    clearTimeout(timeout); try { await terminated; } catch (error) { failure ??= error; report.error ??= String(error); }
    try { writeFileSync(`${file}.stderr.txt`, diagnostic); publish(); }
    catch (error) { if (failure instanceof Error) failure.diagnosticFailure = String(error); else failure ??= error; }
  }
  if (failure) throw failure;
  console.log(`verified actual native resource v${version} ${caseName}`);
}
