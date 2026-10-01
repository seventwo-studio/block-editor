# Current v3 order and ancestry measurements

The current default c3ffbf16ccb461864be8f9e36d6eed86250f51cd plus the two engine changes in this delivery was built with Swift 6.4 release optimization. `provenance.json` records every core/CLI/package input hash and the exact binary hash. This source was uncommitted during measurement; its input hashes qualify the candidate. The historical `2026-10-01-v3-native-release` bundle remains unchanged under its original source identity.

The engine caches each byte-exact origin encoding while sorting; its order still matches the original public comparator. The retained-boundary ancestry projection is constructed only when an active anchored split needs its rank. The final full projection and replay validation still execute. Unicode normalization must not merge distinct origin bytes; the ordering regression checks exact UTF-8 bytes.

One excluded warmup and three measured repetitions ran per case in one native bridge process, with no other local build or performance campaign deliberately scheduled. OS/background load and disk caches were uncontrolled. All per-call timings and expected rich document/history assertions are retained in `performance-native.json`.

| Workload | Offline-edit p95 per repetition (ms) | Larger of the two rejoin calls per repetition (ms) |
| --- | --- | --- |
| ordinary-v3 | 15.40 / 15.23 / 15.65 | 39.18 / 38.86 / 40.14 |
| history-v3-128 | 18.25 / 18.43 / 18.01 | 112.05 / 114.54 / 114.74 |

The release CLI is 2,425,296 raw bytes and has SHA-256 `5cdd3f6f09bb98fcf148fa34297cc8d8d3873f784b634f9f9fc966014c69e681`; this excludes installed Swift runtime and all platform packaging. The one fresh-process-to-empty-session observation is 245.82 ms, with uncontrolled disk caches. It is not a repeated disk-cold or device startup result. Warm create p95 was 12.85–14.05 ms. No memory campaign was performed in this slot.

All 3,047 native fixture responses passed, including 346 writing requests and the new 24-request nested rich-range/move/duplicate/undo/reopen fixture. The independent six-case retained-history oracle passed for v1/v2/v3 in both undo/redo packet orders. The source Swift suite passed 149 functions. `verification.json` records fixture hashes, exact counts and the native transcript hash. Fresh JNI/API 26/current-architecture and Chromium/WebKit/Firefox parity are still required from delivery CI; these local results are not device input acceptance.

Numeric release budgets remain **unagreed**. The small case is below the proposed 16 ms edit-call limit, while the 128-edit case exceeds it. Rendering, browser timing, network, assets, physical input, Android/Apple memory and install size are excluded. Larger 512/2,048-edit histories require a separately serialized follow-up. This evidence does not close ST-94 or ST-39.

Reproduce with the exact source inputs recorded here, a release `editor-bridge`, Node 24.19, and the portable runner:

```sh
PERFORMANCE_CASES=ordinary-v3,history-v3-128 PERFORMANCE_REPETITIONS=3 PERFORMANCE_WARMUPS=1 \
  node scripts/run-native-v3-performance.mjs /absolute/release/editor-bridge \
  test-results/performance/current-v3.json benchmarks/workloads-v3.json /absolute/source-metadata.json
```
