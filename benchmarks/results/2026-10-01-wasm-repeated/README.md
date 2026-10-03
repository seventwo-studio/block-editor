# Repeated WASM baseline at e787146

Chromium and WebKit each completed eight cases, one excluded warmup and three recorded repetitions per case: **48 complete browser samples**. Firefox failed during browser launch before the test ran; it produced zero samples and no canonical report. This dataset does not establish the full three-browser baseline. The failure log is preserved and no retry was performed after the request to wrap up.

The measurement checkout was clean at source `e787146c432e649e71a1a6423fe4a24c55e21f5c`. The WASM artifact was rebuilt from that exact checkout using the cached official Swift 6.4 toolchain and matching WASM SDK. [Provenance](provenance.json) records source objects, compiler binary hash/version, SDK manifest/hash, exact build command, artifact hash and runtime metadata. The [build log](wasm-build.log) records success in 11.33 seconds. These are archived measurements of e787146, **not measurements of later ST-96 / PR #34 engine changes**.

The fresh release artifact has SHA-256 `d659fd2f1212d8242e3c18397f69a540cf76d23c63cd2e073eba15a669518457`, **61,435,676 raw bytes** and **20,370,961 computed gzip level-9 bytes**. Gzip is a computation, not deployed compression or installed application size. A prior reused-artifact Chromium run had a different hash and remains [separate screening](../2026-10-01-wasm-screening-reused/README.md); it is excluded from the fresh baseline verifier.

Host: Apple M4 Max; full host, OS and runtime values are in each raw report. Browser runs were sequential. Background load and OS/browser caches were uncontrolled. Timings include UTF-8, JSON and WASM memory copies through `SwiftEditorRuntime.call`; network transfer, rendering and input-to-frame latency are excluded. Fetching local module bytes precedes initialization timing. Compilation is one observed initialization per browser, not three cold launches or a cold-cache startup claim.

## Edit-call p95

Each entry lists repetitions 0/1/2 in milliseconds. Three repetitions are observations, not a statistical confidence interval or accepted budget. Native values come from the separately preserved earlier optimized report at `1e527807f630d77b4f41029bd951371782417dd2`, with JSON/pipe overhead rather than WASM copies. Its raw data remains unmodified in `/Users/luca/.codex/worktrees/nested-structure/block-editor/benchmarks/results/2026-10-01-repeated/` and is not copied into this dataset.

| Case | Native archive | Chromium 153.0.8010.12 | WebKit 26.6 |
| --- | ---: | ---: | ---: |
| ordinary-v1 | 0.85/0.83/0.82 | 1.00/1.00/1.00 | 1.00/1.00/1.00 |
| ordinary-v2 | 3.77/3.63/3.55 | 4.50/4.60/4.50 | 5.00/4.00/5.00 |
| history-v1-128 | 0.79/0.81/0.80 | 1.10/1.10/1.10 | 1.00/1.00/1.00 |
| history-v1-512 | 1.25/1.24/1.25 | 1.80/1.80/1.80 | 2.00/2.00/2.00 |
| history-v1-2048 | 3.26/3.30/3.30 | 5.00/5.00/5.00 | 5.00/5.00/5.00 |
| history-v2-128 | 4.77/4.79/5.25 | 6.10/6.20/6.20 | 6.00/6.00/6.00 |
| history-v2-512 | 9.52/9.48/9.50 | 12.70/12.70/12.70 | 12.00/12.00/12.00 |
| history-v2-2048 | 28.62/29.05/31.85 | 41.00/41.40/41.50 | 38.00/38.00/38.00 |

At 2,048 v2 edits per author, total time for the two rejoin calls is **1173.40/1160.00/1136.50 ms** in Chromium and **1001.00/992.00/1014.00 ms** in WebKit. The separately preserved native values are **918.50/948.67/1007.64 ms**.

## Observed initialization

| Browser | Compile ms | Compiled-module instantiate ms | First empty session ms |
| --- | ---: | ---: | ---: |
| chromium 153.0.8010.12 | 21.50 | 8.80 | 7.90 |
| webkit 26.6 | 40.00 | 10.00 | 8.00 |

## Correctness and verification

The workload independently checks both authors' text and formatting, preserved Unicode/references/opaque content, duplicate receives, fresh history replay, save/reopen, receipts and local undo retaining remote edits. The largest case retains **4,098 changes and receipts**. Neither this finite workload nor three repetitions establishes unbounded-history scalability, compaction or memory limits.

The [independent verifier output](verification.txt) confirms both complete browser reports against the full baseline profile and exact archived source. The native report was independently verified at its own archived source. An additional canonical comparison confirms that corresponding samples among the **72 completed samples** across the native archive and both browsers have matching final documents, history counts and receipts; the digest and original native report hash are in provenance. Source stamps were not relabeled to make that comparison.

```sh
bun scripts/compare-performance-reports.mjs \
  benchmarks/results/2026-10-01-wasm-repeated \
  wasm-chromium,wasm-webkit baseline \
  --source=e787146c432e649e71a1a6423fe4a24c55e21f5c
```

[Chromium raw report](performance-wasm-chromium.json) · [WebKit raw report](performance-wasm-webkit.json) · [Firefox launch failure](firefox-playwright.log) · [Methods](../../../docs/editor-performance.md)

## Open acceptance

The earlier discussion targets of edit-call p95 ≤16 ms, two-call rejoin ≤1 second and WASM gzip ≤10 MB remain **unagreed proposals**. The large v2 cases exceed the proposed edit target, some rejoin samples exceed the proposed rejoin target, and this artifact exceeds the proposed gzip target. No numerical criterion is checked and no improvement is treated as mandatory until the budgets and boundaries are agreed.

Full Firefox repeated measurements, repeated JNI/device baselines, actual minimum/current-device startup and sustained input, rendering/accessibility, peak memory, limits and separate compaction/size work remain open. Hosted Firefox compatibility success does not replace the missing local full benchmark. This archived dataset retains its original source and artifact qualifications; preserving it does not establish current-engine or package acceptance.
