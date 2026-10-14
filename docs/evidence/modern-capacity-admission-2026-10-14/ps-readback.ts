import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { verifyAndroidProcessStop } from '../../../../scripts/verify-android-process-stop.ts';
const adb = '/Users/luca/Developer/block-editor/.build/finishing/20261014/android-relay/sdk/platform-tools/adb';
const reads: Array<{ args: string[], actualExit: number | null, injected255?: boolean }> = [];
const result = await verifyAndroidProcessStop(async args => {
  const r = spawnSync(adb, ['-P', '5044', '-s', 'emulator-5568', ...args], { encoding: 'utf8' });
  const text = r.stdout + r.stderr;
  const record = { args, actualExit: r.status, injected255: undefined as boolean | undefined }; reads.push(record);
  if (args[1] === 'pidof' && r.status === 1 && !text.trim()) {
    record.injected255 = true;
    throw Object.assign(new Error('Injected empty API26 pidof status after actual absent read'), { exitCode: 255, output: '' });
  }
  if (r.status !== 0) throw Object.assign(new Error('Actual Android command failed'), { exitCode: r.status, output: text });
  if (args[1] === 'ps') writeFileSync('.build/finishing/20261014/capacity-bound/actual-ps.txt', text);
  return text;
}, 'studio.seventwo.blockeditor.test');
if (result.processReadback !== 'ps') throw new Error('Fallback was not exercised');
writeFileSync('.build/finishing/20261014/capacity-bound/ps-readback.json', JSON.stringify({ result, reads, qualification: 'Actual owned API35 arm64 emulator process listing and stop, with empty-255 status synthetically injected only after a real pidof absent-process response. Not an API26 rerun.' }, null, 2) + '\n');
console.log(result);
