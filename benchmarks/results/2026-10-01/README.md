# Initial screening measurements

These are initial observations of engine revision
`31a62488748292ba24cbd41dc0a41afbf05aacae`, collected during development of the
measurement harness delivered in `0230d70`. The engine, ABI and production wrapper
sources were unchanged. Reports retain their original revision and dirty-state
metadata where available; they are not relabeled as measurements of a later commit.

All eight workloads passed in optimized native Swift, actual API 35 ARM64 JNI and
Chromium/WebKit WASM. The four reports have the same workload hash, retained
history/receipts and final documents. Each case has **one recorded repetition and
no excluded warmup**. This screening run does not replace the default three-repeat,
one-warmup baseline, physical-device measurements or accepted numeric budgets.

Native and browser hosts were Apple M4 Max; Android used the running API 35 ARM64
emulator on that host. Reports record OS/kernel, browser versions, VM/virtual
hardware, artifact hashes and exact timing boundaries. Local runners executed
sequentially. OS caches and background load were uncontrolled.

| Case | Native edit p95, ms | Android JNI, ms | Chromium WASM, ms | WebKit WASM, ms |
| --- | ---: | ---: | ---: | ---: |
| Ordinary v1, 24 edits/author | 0.85 | 2.35 | 1.80 | 3.00 |
| Ordinary v2, 24 edits/author | 3.54 | 4.35 | 5.70 | 5.00 |
| v1, 128 edits/author | 0.81 | 1.00 | 1.10 | 1.00 |
| v1, 512 edits/author | 1.27 | 1.51 | 1.80 | 2.00 |
| v1, 2,048 edits/author | 3.26 | 3.97 | 4.90 | 4.00 |
| v2, 128 edits/author | 4.68 | 4.90 | 5.90 | 6.00 |
| v2, 512 edits/author | 9.29 | 10.22 | 12.40 | 12.00 |
| v2, 2,048 edits/author | 28.70 | 35.59 | 38.80 | 36.00 |

The largest workload retains 4,098 changes/receipts. Native host JSON snapshots
grow from 70,119 to 1,058,410 bytes for v1 and from 85,341 to 1,300,192 bytes for v2
between 128 and 2,048 edits per author. There is no compaction in this workload.
Local undo still retains every remote character and the remote italic formatting.

The WASM artifact is 61,435,676 raw bytes and 20,370,967 bytes with computed gzip
level 9. The native CLI is 1,350,752 bytes but depends on Apple system libraries.
Android's selected-ABI library sizes and APK compression are recorded separately;
they include the static Swift runtime and NDK C++ runtime. These are different
packaging boundaries, not equivalent installed application sizes.

The v2 local edit path currently re-encodes the complete candidate history and
edit-ID reserve during each capacity check (`EditorSession.checkRecoveryCapacity`).
This is an avoidable growing-history cost to investigate and reduce while preserving
the exact admission/recovery limits. These observations alone do not attribute all
v2 overhead to that method or establish an agreed latency/package budget.

Raw reports retain individual timings, initialization and artifact evidence:

- [Native](performance-native.json)
- [Android API 35 ARM64 JNI](performance-android-api35-arm64-v8a.json)
- [Chromium WASM](performance-wasm-chromium.json)
- [WebKit WASM](performance-wasm-webkit.json)

Verify this historical screening dataset explicitly:

```sh
bun scripts/compare-performance-reports.mjs benchmarks/results/2026-10-01 \
  native,android-api35-arm64-v8a,wasm-chromium,wasm-webkit \
  --source=31a62488748292ba24cbd41dc0a41afbf05aacae
```

See [measurement methods and reproduction](../../../docs/editor-performance.md).
