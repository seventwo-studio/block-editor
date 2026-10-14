# Negotiated accepted snapshot responses

Matching engines advertise documentSnapshotVersion 1. Snapshot-producing calls
opt in explicitly, then name the token of their exact previously returned
snapshot. Swift retains one ephemeral view per live session generation and
returns bounded replacements only against a matching token. Unknown tokens,
new generations and large diffs return complete documents. Default callers keep
their original full response shape; shared admission/mutations/history and saved
checkpoints remain unchanged.

Comparisons preserve exact Unicode bytes and number bit patterns, including
signed zero. Complete current receipt/history/recovery/command outcomes remain
present even when content is unchanged. The TypeScript adapter checks
scope/version/base token and disjoint existing paths before immutable document
reconstruction. Malformed advertised responses fail without publication; old
engines retain full responses. Owned-object reuse recognizes only completed
ownership walks, not foreign shallow freezes. Kotlin exposes the optional
capability while retaining its full-response default.

Final builders pin clean 879574f with identical source inputs. Full native
regression passes 605 core +104 Apple +eight other =717 tests. Three focused
bridge cases cover opt-in/default shape, an intervening default-caller edit,
exact opaque Unicode/zero changes, bounded fallback, rejected options and handle
replacement. Eight adapter cases/60 expectations cover exact complete documents,
ownership, same-value peer receipts and malformed responses.

All 66 integrated browser cases pass across Chromium, WebKit and Firefox.
Native ABI passes 968 responses/30 fixtures; typed native passes 535 requests/55
fixtures/26 commands/12 groups. Extra capability reads change the request count
from earlier 515; those counts retain their sources. Both Android ABIs and the
matching APK build. The actual default-response JNI consumer passes with explicit
terminal code -1 and matching runtime bytes. It is one consumer, not a full
rendered Compose/device or Kotlin-delta campaign. Emulator stopped before timing.

An actual 1,000-block WASM diagnostic returns 2675/2721-byte edits versus a
522150-byte full snapshot. Independent complete documents and direct shared
reads match after each edit and grouped Undo/Redo. This is response-size/API
preservation evidence, not percentile or resource acceptance.

| Browser | Typing p95 | Menu p95 | Result |
| --- | ---: | ---: | --- |
| Chromium | 145.8 ms | 26.8 ms | Input failed; menu passed |
| WebKit | 191 ms | 35 ms | Input failed; menu passed |
| Firefox | 215 ms | 36 ms | Input failed; menu passed |

The frozen original 1,000-block workload completes all twenty samples after
three warmups with accepted/rendered content and menu-focus assertions. Every
report retains clean source, fixture and measured WASM hashes. All three combined
tests correctly fail the unchanged 50 ms input target. Menus meet 100 ms for this
workload. Original failed measurements remain separate; smaller responses and
lower current samples do not establish full performance/resource acceptance.

Further shared authoring/replay and rendering work, current hosted CI/review,
comprehensive campaigns, private native delivery, deferred physical checks and
explicit final acceptance remain required. Existing lint failure remains open.
Protected main, immutable private 0.2.0, grants, credentials and concurrent
Foliostrate work remain unchanged. [Receipt](receipt.json), original logs,
prior receipts and [hashes](hashes.json) retain exact sources and qualifications.
