import { readFileSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fixtureNames, canonical } from './compatibility.mjs';

const root = resolve(process.argv[2] ?? 'test-results/compatibility');
const expected = (process.argv[3] ?? 'native,android-api26-x86_64,android-api35-x86_64,android-api35-arm64-v8a,wasm-chromium,wasm-webkit,wasm-firefox').split(',');
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? files(join(dir, entry.name)) : [join(dir, entry.name)]);
}
const allFiles = files(root);
const reports = expected.map(name => {
  const matches = allFiles.filter(path => path.endsWith(`/${name}.json`));
  if (matches.length !== 1) throw new Error(`Expected exactly one ${name} report, found ${matches.length}`);
  const report = JSON.parse(readFileSync(matches[0], 'utf8'));
  if (report.version !== 1) throw new Error(`${name}: unsupported report version`);
  if (!isDeepStrictEqual(Object.keys(report.fixtures).sort(), [...fixtureNames].sort())) throw new Error(`${name}: missing or unexpected fixture results`);
  for (const fixture of fixtureNames) {
    const hash = createHash('sha256').update(readFileSync(`tests/BlockEditorCoreTests/Fixtures/${fixture}.json`)).digest('hex');
    if (report.fixtureHashes[fixture] !== hash) throw new Error(`${name}: stale ${fixture} input`);
    const source = JSON.parse(readFileSync(`tests/BlockEditorCoreTests/Fixtures/${fixture}.json`));
    const count = fixture === 'documents' ? source.valid.length * 5 + source.invalid.length : (source.requests ?? source.steps).length;
    if (report.fixtures[fixture].responses.length !== count) throw new Error(`${name}: incomplete ${fixture} transcript`);
  }
  return { name, report: canonical(report) };
});
for (const { name, report } of reports.slice(1)) {
  if (!isDeepStrictEqual(report, reports[0].report)) {
    for (const fixture of fixtureNames) {
      const actual = report.fixtures[fixture].responses;
      const baseline = reports[0].report.fixtures[fixture].responses;
      for (let index = 0; index < baseline.length; index++) {
        if (!isDeepStrictEqual(actual[index], baseline[index])) {
          throw new Error(`${name} differs from ${reports[0].name} in ${fixture} response ${index}:\n${JSON.stringify(actual[index])}\nexpected:\n${JSON.stringify(baseline[index])}`);
        }
      }
    }
    throw new Error(`${name}: report metadata differs`);
  }
  console.log(`${name}: all documents, histories, receipts, selections and protocol errors match ${reports[0].name}`);
}
console.log(`Verified ${reports.length} runtime reports against the exact shared fixture inputs.`);
