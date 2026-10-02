# Native protocol-4 ordinary-writing measurements, 2 October 2026

These are qualified measurements of merged core tree `81690ced07c3aeca27695e229b5dfb13358046c6` (Verified merge `f946b5fd`), with the exact feature-source commit `01f8647632e732621fc7686b435d39a9ba14c182` retained in both original reports. They do not establish release acceptance or agreed numeric budgets.

The release bridge was built at additive runner overlay `dac0001c075226e9401445e972e598ef9bdd7514`; its Swift and Package sources equal the merged core. Binary SHA256 is `ba6043a113c370e9df72e2d81972f0c760bad6bea463ddb2575cf2882ba72d2a`, raw size **2,969,488 bytes**. The small campaign used that original runner. The wide campaign used separately reviewed strict-metadata runner tree `7a93f3c9d1bdf0cef0de35f3c076a8a423f55488`, SHA256 `f757c5ce4a491419432c440ccb21223d7b9c6447c07e86cb3161031b7603c21f`, with the same binary and workload. Preserve build and measurement-runner identities separately; validation-only runner repairs did not change timed operations.

Both campaigns completed correctness, Unicode, rich formatting/reference, identity, receipt and author Undo/Redo assertions. Each case uses sixteen baseline blocks, two offline authors, one warmup and three measured repetitions. The following ranges summarize the three repetitions, rather than pooling their samples.

| Edits per author | Edit p95 ms | Two receive calls, total rejoin ms | Largest Undo call ms | Restore ms | Accepted snapshot bytes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 15.35–15.50 | 67.32–67.83 | 15.09–15.30 | 68.74–69.87 | 48,656 |
| 128 | 18.07–18.46 | 182.08–185.29 | 21.25–21.91 | 195.78–197.30 | 179,443 |
| 512 | 29.26–29.45 | 625.53–643.51 | 45.10–46.49 | 665.73–698.78 | 705,523 |
| 2048 | 77.15–78.12 | 2475.32–2488.30 | 144.70–146.11 | 2656.54–2749.43 | 2,821,384 |

Fresh-process initialization was **235.08 ms** in the first small campaign and **7.89 ms** in the later wide campaign. Disk caches were uncontrolled: neither number is a disk-cold startup result. Per-scenario create calls and original timing samples are retained in the reports.

Darwin `/usr/bin/time -l` reports child maximum resident memory in bytes: **67,223,552** for the small campaign and **308,854,784** for the wide campaign. These are peaks across each entire child process, including retained benchmark sessions/history and bridge JSON buffers. They exclude the parent runner and native rendering; they are not one-editor device-memory measurements. Raw resource counters are stored alongside each original report.

The JSON process bridge includes serialization, pipes, response parsing and export assertions. It excludes rendering, network, actual devices, private package installation, schema conversion, list exits and retained-paragraph role-proof replay. It does not accept Apple, Android or browser editor latency/memory budgets. Local heavy builds and exclusive device use were paused during both measured campaigns. Historical v3 measurements and their thirteen original evidence blobs are unchanged.

Run the additive harness with a pinned build manifest (commit, overlay tree, dirty flag, source boundary, debug/release configuration and matching binary SHA256 are mandatory):

```sh
PERFORMANCE_CASES=history-v4-512,history-v4-2048 node scripts/run-native-v4-performance.mjs /path/to/editor-bridge /path/to/report.json benchmarks/workloads-v4.json /path/to/pinned-build.json
```

The runner rejects missing/invalid provenance before spawning the bridge. Nineteen negative provenance cases were independently checked. Missing resource counters or a child failure leave an incomplete report. Numeric budgets remain **unagreed**; current-source schema/role work, actual JNI/WASM artifacts and platform memory/input measurements still belong to ST-94/ST-39 acceptance.
