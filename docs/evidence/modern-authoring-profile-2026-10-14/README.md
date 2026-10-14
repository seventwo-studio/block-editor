# Authoring profile, exact atom ranks and retained field offsets

The direct actual-WASM probe uses the unchanged 1,000-block fixture SHA-256
`03431f1bfdbd765b3baeaf2463caaa72a9e62610482493d71a73e0a3f7e839e3`.
Original appends measured 3,272–3,514 ms. Exact origin ranks (`5f992757`)
measured 3,084–3,116 ms; retained field offsets (`d940e10a`) measured
2,934–2,980 ms. No-op shortcuts still take 142–145 ms; mark state takes
78–79 ms. These are instrumented API diagnostics excluding browser input and
rendering, with two verified appends. They do not establish a p95 or accept the
unchanged 50/100 ms surface targets. The original failed/incomplete 9.4-second
production baseline remains in the preceding surface-read evidence.

The owned native debug bridge sample identifies whole projection construction,
field resolution and repeated origin-byte comparison in author replay. It is
diagnostic, not optimized-native or surface acceptance. Ranked comparison keeps
ElementID priority, exact raw UTF-8 origin order and stable equal-key ties.
Caret reads now scan their resolved field's retained traversal, preserving joined
heads, hidden atoms and historical UTF-16 widths. Literal Unicode/element-order
and tombstone/join/Undo expectations accompany the changes.

The final shared source passed 582 core, 99 Apple and eight other native tests
with normal exit. The actual API35 arm64 HTTP campaign passed all five phases
in five distinct processes, confirmed each terminal state and checked the final
server file through a fresh native session. Fixtures and expected documents are
unchanged. Exact source, diagnostic calls and qualifications are in
[receipt.json](receipt.json); raw logs and hashes remain alongside it.

The current native C ABI passed 968 responses against 30 independent fixtures;
the typed consumer passed 504 requests, 55 fixtures and 26 commands. All 42
affected editor/context/preservation/typed-consumer cases passed in Chromium,
WebKit and Firefox with normal exit. This is functional regression evidence;
the unchanged performance targets and the remaining complete browser matrix
still need acceptance.

WASM was built from the offset worktree before its commit; its receipt correctly
records a dirty base. Every recorded source input matches final `d940e10a`.
Android was built clean at that commit. This is affected runtime verification,
not a clean matching package release or comprehensive native acceptance.

Prior CI `38502356501` at `4510a21f` failed API26 after the seed instrumentation
and saved proof passed: its subsequent `am force-stop` returned exit 255 with
empty output before any offline phase. The cleanup repair (`b87662b5`) confirms
actual package process absence, accepts only empty exit-1 `pidof` readback and
rejects remaining processes or ambiguous/denied reads. All five phase assertions
and distinct-process checks remain required. Three independent injected-outcome
tests pass; actual repaired API26 CI remains required.

The first local matching-APK run failed seed opening with HTTP400. That original
instrumentation/receipt is retained. A separate exact room-opening diagnostic
returned 200, followed by a passing repeat and the final current-source campaign.
The original cause is unproven; its failure has not been relabeled. The earlier
passing repeat mixed ranked JNI and a later native checker, so only the final
current-source campaign establishes matching process evidence. The initial
Android compiler-cache denial and successful authorized retry also remain.

Complete browser/native rendered, assistive, performance/resource, private clean
installation and final acceptance stay open. Physical-device access and Luca's
review remain deferred. Published private 0.2.0 is unchanged; new delivery and
protected-main landing retain their concrete approval and current CI gates.
