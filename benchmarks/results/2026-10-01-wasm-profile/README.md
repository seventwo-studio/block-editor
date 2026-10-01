# Diagnostic history profile

One Chromium 153.0.8010.12 CDP profile was captured for each of
`history-v1-512` and `history-v2-512`, using the original named WASM artifact
`d659fd2f1212d8242e3c18397f69a540cf76d23c63cd2e073eba15a669518457` from
`e787146c432e649e71a1a6423fe4a24c55e21f5c`. The module was initialized before
profiling. Each diagnostic runs one repetition without warmup, with 512 edits
per author and all existing content, mark, receipt, reopen and undo checks.

The interval is 1,000 microseconds. [Provenance](provenance.json) records the
exact capture-script and raw/compressed profile hashes, workload options and
source boundary. The checkout has staged documentation/tooling changes;
production inputs remain unchanged. [Capture log](capture.log) records both
completed cases. OS/browser caches and background load are uncontrolled.

These are sampled renderer execution spans with profiler overhead, harness
validation, JavaScript and WASM calls included. They are diagnostics, not repeated
baselines, bare engine CPU times, speedup predictions or budget acceptance.

| Observation | v1 history 512 | v2 history 512 |
| --- | ---: | ---: |
| Profile samples | 2,014 | 8,329 |
| Sum of sampled intervals (ms) | 2,542.319 | 10,411.529 |
| Largest append frame, inclusive ms (% of sampled intervals) | 383.868 (15.10%) | 5,456.221 (52.41%) |
| Recovery-capacity frame, inclusive ms | Absent from captured stacks | 4,249.639 (40.82%) |
| JSONEncoder.encode under that capacity frame, inclusive ms | — | 4,185.989 (40.21%) |

Inclusive values overlap: JSON encoding is nested inside capacity checking,
which is nested inside append. **Do not add these percentages.** The summaries
retain the top 60 individual frames; identical functions reached through
different stacks can appear more than once. The quoted capacity frame is a
specific captured call path, rather than an aggregate of every function with
that name. Raw profiles retain all nodes and samples for independent analysis.
[Independent verification](independent-verification.json) checks compressed/raw
hash equality, the sample/delta counts, frame-tree structure and recomputed
inclusive capacity weights from the complete profiles.

The v2 profile supports prioritizing the full retained-history encoding in
`EditorSession.checkRecoveryCapacity` for investigation by the shared-core owner.
It does not establish a 40.82% achievable speedup or prove the same distribution
in later engine revisions. Exact incremental encoded-byte accounting still
needs deterministic admission/recovery, retained receipts, offline merge,
restart/reopen and remote-preserving author undo verification. No core change
was implemented by this measurement task.

## Inspect or reproduce

The complete profiles are compressed losslessly:
[v1 profile](history-v1-512.cpuprofile.gz),
[v2 profile](history-v2-512.cpuprofile.gz).
Decompress to a new owned file and open the `.cpuprofile` in a compatible CPU
profile viewer. Uncompressed SHA-256 values are in provenance; the original raw
files remain in `/tmp/editor-wasm-cpu-profile-20261001/`.
[v1 summary](history-v1-512.json) and [v2 summary](history-v2-512.json) retain the
measured workload results and self/inclusive sampled weights.

[capture.mjs](capture.mjs) is the exact executed script, preserved as evidence.
Run it from a checkout with the recorded production inputs, named artifact and
existing pinned dependencies only after reserving the browser resource. Adapt
its fixed output directory to a new owned directory before another capture; the
archived script would otherwise overwrite the original diagnostic files.
It uses an owned Vite server on 4297 and a separate cache directory, then closes
the browser and server. No further capture is needed for these unchanged inputs.
