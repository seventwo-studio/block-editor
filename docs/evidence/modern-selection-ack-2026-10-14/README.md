# Checked compact local selection acknowledgements

Matching protocol-7 engines advertise localSelectionAckVersion 1. Explicit
includeSnapshot=false requests still validate and retain selection and typing
boundaries in Swift, returning an acknowledgement with version 1 and the exact
document/epoch. Omitted or true options retain historical complete responses.
The TypeScript adapter checks acknowledgement scope/version, preserves the
accepted immutable snapshot and notifies persistence subscribers. Older engines
retain the full path; advertised validation/lifecycle failures propagate.
Kotlin exposes the capability and retains its historical default response.

An original one-edit Chromium diagnostic at 02725213 records about 161 ms for
shared replaceText and 78 ms for three local-selection snapshot updates. Its CDP
profile is diagnostic, not percentile or resource acceptance. No document
mutation, capacity bound, captured target or history rule is bypassed by the
compact response.

All final builders pin clean c5c015a and identical source inputs. Full native
regression passes 601 core + 104 Apple + eight other = 713 cases. Shared bridge
checks cover compact/default responses, complete content/save invariance,
backward Undo/Redo and paired reopen, malformed option and foreign-scope
rejection. Six adapter cases/35 expectations verify notifications, immutable
snapshots, failures and older-engine fallback. All 66 integrated browser cases
pass on this same source. The native ABI verifies 968 responses/30 fixtures;
typed native verifies 515 requests/55 fixtures/26 commands/12 groups.

Both Android ABIs and the matching test APK build. Actual owned API35 JNI typed
consumer passes with explicit terminal instrumentation code -1. Original
missing-device and debug-signature installation failures are retained. The
previous owned test package and data were archived locally before replacing
only that test package; this directory retains hashes, not that private binary
archive. Plain/raw instrumentation runs repeat the same consumer, not two
independent cases. It is not a full rendered Compose/device campaign. The
isolated emulator was stopped before browser timing.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 232.6 ms | 46.2 ms | Input failed; menu passed |
| WebKit | 294 ms | 64 ms | Input failed; menu passed |
| Firefox | 347 ms | 83 ms | Input failed; menu passed |

The frozen original 1,000-block workload completes every twenty sample after
three warmups. Each report retains clean source, original fixture and measured
WASM hashes, accepted/rendered text and menu-focus checks. All combined tests
correctly exit with failure on the unchanged 50 ms input target. Menus meet
100 ms for this workload. Earlier failed measurements remain separate; lower
current samples do not establish full performance or resource acceptance.

Current hosted CI/review, further typing/rendering work, comprehensive campaigns,
private native delivery, deferred physical checks and explicit final acceptance
remain required. Existing lint failures are not accepted as a pass. Protected
main, private 0.2.0, grants and concurrent Foliostrate work remain unchanged.
[Receipt](receipt.json), original logs, prior receipts and [hashes](hashes.json)
retain exact sources and qualifications.
