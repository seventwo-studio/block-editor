ST-94 bounded native v3 release measurements

Preserved bounded evidence. Swift 6.4 release bridge uses frozen f97db302 default plus the qualified 907b586f v3 core/ABI overlay. The original checkout remains e787 with its 35 delivered staged files; archives are unchanged. Original build/source commands and all 17 input hashes are in original-build-plan.json; portable source metadata is in provenance.json.

Release CLI: 2,241,280 raw bytes, SHA256 6f25b88500c1561f2750ba8fdfcc36d8eaa4df9cd20e653ad6921387ad4a4468. This excludes the installed system Swift runtime. Exact 2,934-response compatibility transcript matches qualified native/Chromium/WebKit/Firefox byte for byte (bcade61965a96973ae67504f051df498ccc8cf59832054f723bf663f8dbe8eba).

One excluded warmup and three measured repetitions per case; six measured samples completed in 68.21 seconds. Every edit-call timing is retained in performance-native.json.

| Edits per author | Edit-call p95 per repetition (ms) | Sum of two rejoin calls per repetition (ms) | Accepted changes / receipts | Snapshot bytes |
| --- | --- | --- | --- | --- |
| 32 | 45.33 / 43.81 / 43.49 | 122.10 / 121.89 / 122.66 | 66 / 66 | 46086 |
| 128 | 50.37 / 50.53 / 69.69 | 236.47 / 250.82 / 256.49 | 258 / 258 | 169135 |

All correctness checks passed: v3 export version/document/epoch; local-author save history; Unicode and unrelated rich content/metadata preservation; reversed and duplicate delivery convergence; exact accepted change and receipt counts; fresh peer replay; save/reopen; author-specific formatting and insertion undo/redo preserving remote content. Final documents are identical across the three repetitions of each case. Original independent verification recomputes counts, percentile/total values and hashes in original-verification.json.

Timing includes native JSON serialization, pipes, parsing and export identity assertions. It excludes rendering, asset fetch and network. Android instrumentation was authorized to run independently during this reserved slot; host/background load was not controlled. There is no claim of bare engine latency or physical-device UI response. One fresh process-to-empty-v3-session observation was 5.72 ms with uncontrolled disk caches; this is not a repeated disk-cold/device startup measurement.

The measurements exceed the proposed, unagreed 16 ms edit-call target. They do not constitute an accepted gate failure. The broader 512/2,048-edit cases were not executed in this slot; they need a separately reserved bounded follow-up. No speedup or regression is inferred against earlier v1/v2 or debug measurements. Browser v3 timing, physical-device startup/editing, installed size, memory and required improvements remain open; human numeric-limit/gate-policy agreement is pending.

The raw report, exact executed-runner.mjs.txt, original provenance and logs are preserved byte for byte. The compressed compatibility transcript is lossless. The historical runner records original absolute paths; use scripts/run-native-v3-performance.mjs and benchmarks/workloads-v3.json for portable future runs. The CLI, SDKs and build caches remain local and are excluded from this evidence bundle.

Reproduction requires [the ST-42 v3 core dependency, PR #44](https://github.com/seventwo-studio/block-editor/pull/44). Check the measured input hashes in provenance.json against that source before comparing results. The archived report describes the original f97+907 input freeze; a later PR head must not relabel those timings.

Build a release editor-bridge with Swift 6.4 using private scratch/cache/config/security/module paths. Run a new report against the resulting binary:

```sh
PERFORMANCE_CASES=ordinary-v3,history-v3-128 PERFORMANCE_WARMUPS=1 PERFORMANCE_REPETITIONS=3 \
  node scripts/run-native-v3-performance.mjs /absolute/release/editor-bridge \
  test-results/performance/v3-native.json benchmarks/workloads-v3.json
```

The optional final argument after the workload path is source metadata JSON with sourceCommit, sourceDirty, optional sourceOverlayTree and optional artifactSHA256; a supplied artifact hash must match before execution. Record fresh build hashes for fresh binaries. Without metadata the source stamp describes the invoking checkout and does not qualify the supplied binary. The portable runner retains the original v3 epoch/export/local-history checks; it rejects v1/v2 cases before launching a process. It is a portability adaptation, not the script used for the archived timings.

Validation for this delivery uses the archived report and failure checks; no new measurement campaign was run. Numeric budgets remain proposals.

All 17 measured native/core/ABI/WASM/CLI source hashes also match PR #44 head 225b6b0c29094c196855e8af948a8f566e9c5ff3. This establishes input equivalence and preserves the historical f97+907 timing stamp.
