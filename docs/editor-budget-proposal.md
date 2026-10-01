# Editor budget proposal

ST-94 has reproducible measurements and an initial numerical proposal. **No
numerical budget is agreed.** This document records the proposed boundaries,
measured gaps and evidence required for a decision. Passing runtime CI checks
workload correctness; it does not accept these limits.

## Evidence and scope

The [three-browser archive](../benchmarks/results/2026-10-01-wasm-three-browsers/README.md)
contains 72 complete samples at source
`e787146c432e649e71a1a6423fe4a24c55e21f5c`: eight cases, one excluded warmup and
three repetitions in Chromium 153.0.8010.12, WebKit 26.6 and Firefox 155.0.
Corresponding documents, retained changes and receipts match the separately
verified 24 native samples at `1e527807f630d77b4f41029bd951371782417dd2`.
These sources remain historical; newer recovery/writing implementations require
their own measurements before current acceptance.

The host is Apple M4 Max with 38,654,705,664 bytes of memory on Darwin 27.0.0.
Caches and background load are uncontrolled. [Methods](editor-performance.md)
define JSON/adapter overhead, timings and preservation checks. Repetition p95
values summarize calls within that repetition, not application launches.
Firefox's integer millisecond clock can report a sub-resolution first call as
zero; that observation does not establish zero execution cost.

The retained Android report is screening at source
`31a62488748292ba24cbd41dc0a41afbf05aacae`, with one repetition and no warmup in
an API 35 ARM64 emulator. The selected-ABI libraries total 82,176,712 raw bytes:
72,681,776 bridge, 9,904 JNI adapter and 9,485,032 C++ runtime. That packaging
boundary includes the static Swift runtime and differs from the 1,350,752-byte
native CLI, which uses Apple system libraries. Neither is an installed app-size
baseline. Repeated JNI and physical minimum/current-device evidence remain open.

## Proposed numerical limits

Use decimal bytes for the size proposal: **10 MB means 10,000,000 bytes**. This
unit choice is part of the proposal and still requires agreement.

| Metric | Proposed limit | Measurement and evaluation |
| --- | --- | --- |
| Edit call | p95 ≤16 ms | Evaluate each recorded repetition of every default case through the declared adapter; include both collaboration versions and 2,048 edits per author. |
| Offline rejoin | ≤1,000 ms | Total of the two rejoin receives in each recorded repetition, with reversed/duplicate delivery and preserved content/receipts. |
| Browser artifact | ≤10,000,000 bytes | Computed gzip level 9 of the exact compatible WASM artifact; record hash and raw size. Deployed compression and complete package size require separate evidence. |
| Startup | Pending measurements and decision | Record fresh-process/library or compile/instance/first-session phases separately. One observation per browser cannot establish a startup p95 or cold-start cap. |
| Native/Android installed size and peak memory | Pending measurements and decision | Measure the approved package/install boundary and devices before selecting numerical limits. |

The 16 ms value is an engine/adapter proposal. An input-to-frame requirement
needs a separate rendered measurement and time for host rendering; an engine
call consuming 16 ms does not establish smooth input. Rejoin excludes network
transfer. These proposed caps apply to the specified finite workload; they do
not grant permission to discard history, receipts, IDs, Unicode or remote edits.

The decision must name the supported device/browser matrix, cache conditions,
source/artifact, workload, evaluation rule and whether these are blocking release
limits or investigation triggers. Current M4 Max observations alone cannot
accept minimum-device limits. Do not add CI timing gates until that decision is
recorded in ST-94 and the repository.

## Observed gaps

At 2,048 edits per author, v2 retains 4,098 changes and receipts. Values below
list repetitions 0/1/2; no source has been relabeled to combine the archives.

| Runtime | Edit-call p95 (ms) | Two-call rejoin (ms) |
| --- | --- | --- |
| Native archive | 28.62 / 29.05 / 31.85 | 918.50 / 948.67 / 1,007.64 |
| Chromium | 41.00 / 41.40 / 41.50 | 1,173.40 / 1,160.00 / 1,136.50 |
| WebKit | 38.00 / 38.00 / 38.00 | 1,001.00 / 992.00 / 1,014.00 |
| Firefox | 52.00 / 52.00 / 50.00 | 1,546.00 / 1,469.00 / 1,454.00 |

Every largest v2 edit repetition exceeds the proposed 16 ms cap. Some native and
WebKit rejoin repetitions exceed 1,000 ms; all Chromium/Firefox largest v2 rejoin
repetitions exceed it. Firefox v2 at 512 edits also reaches 16/17/16 ms, so a
smaller workload cannot be assumed to pass uniformly. Ordinary v2 edit-call p95
is 3.55–3.77 ms native, 4.50–4.60 Chromium, 4–5 WebKit and 6 Firefox.

The original WASM artifact is 61,435,676 raw / 20,370,961 computed gzip bytes.
[Exact section analysis](../benchmarks/results/2026-10-01-wasm-size/README.md)
measures a name-only candidate at 54,630,266 raw / 19,307,383 gzip bytes, saving
1,063,578 gzip bytes (5.22%). Its executable section bytes match the original.
This packaging improvement cannot reach the proposed 10 MB limit.

Observed browser initialization totals are 38.2 ms Chromium, 58 ms WebKit and
94 ms Firefox after local byte fetch. The native process's first empty session
is 8.63 ms and screening JNI first-call/library access is 6.99 ms. These are
single observations with different boundaries; they cannot be turned into a
startup percentile, Activity startup or a cold-cache acceptance claim.

## Next measurements and improvements

1. Preserve a named artifact for profiling. Test the separate name-only candidate
   against complete compatibility transcripts and preserved-content smoke in
   all three browsers before adopting a packaging change. The separate candidate
   now passes six such tests, with matching 2,297-response transcripts and six
   complete smoke samples. Removing the custom
   `name` section leaves standard sections unchanged; it also removes useful
   profiler/debugging labels. No default build flag is changed by this proposal.
2. Capture a linker map before attributing the 37,657,082-byte data payload and
   16,619,360-byte code payload to particular SDK libraries. Static archive sizes
   and symbol names identify investigation candidates, not final-byte ownership.
   Any smaller Foundation/Unicode dependency must preserve Unicode, regex,
   Markdown, URL validation and protocol behavior across runtimes.
3. The [diagnostic v1/v2 history profiles](../benchmarks/results/2026-10-01-wasm-profile/README.md)
   now support prioritizing retained-history capacity encoding: its v2 frame
   accounts for 4,249.639 ms, or 40.82% of sampled intervals, including nested
   JSON encoding. This single profiled repetition includes instrumentation
   overhead and does not establish an achievable speedup or current-source
   distribution. Findings have been sent to the shared-core owner. Incremental
   byte accounting or traversal
   caches must preserve atomic admission/recovery, deterministic limits, exact
   receipts, restart/reopen and remote-preserving local undo.
4. Coordinate repeated JNI with Android acceptance, then collect physical
   minimum/current-device startup, sustained input, rendering and peak memory.
   Avoid another full historical browser run unless an artifact changes or a
   specific uncertainty requires it.

Once numerical limits are agreed, create separate required size, execution or
compaction work for measured failures and relate it to ST-94/ST-96 as appropriate.
Compaction needs an explicit snapshot/cutover/recovery contract that retains
offline authors' content and author undo; a passing 4,098-change workload does
not establish unbounded retention. Until agreement, these remain investigation
proposals, and ST-94/ST-39/ST-106 retain their budget acceptance gates.
