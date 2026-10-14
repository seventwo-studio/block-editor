# Android modern relay, exact input and process recovery

The native Android adapter and runnable reference are implemented at
`d453cbf1597072cf8523b97c5166bb239d24acec`. The corrected peer fixture is
`f96dc84f0ce8d5584bf7aaa97032f813d6676072`. Shared Swift/C sources stayed identical
to `b2d6502c46fcb8de8802a47d683fedaafbd8196a` throughout this local JNI build and
campaign. [receipt.json](receipt.json) pins source files, APK/JNI hashes and local
SDK identities; [files.json](files.json) hashes the retained results.

| Boundary | Result |
| --- | --- |
| Actual JNI / app-private paired store lifecycle | Nine modern host cases passed |
| Streaming/strict JSON, default JNI and all supported epochs | Seven cases passed |
| Existing typed modern JNI consumer | One case passed |
| Default HTTP and separate native/server processes | Five phases passed, five distinct Android PIDs |
| Android editor/reference/test APK compilation | Passed |
| Typed process runner / modern tests and workflow syntax | Passed |

The lifecycle cases cover ordinary empty-queue reopen, read-only peer delivery,
failed ACK save/retry, input during transmission, host/credential ABA, valid
rejected recovery and explicit own-only repair, held peer packets and inert
original input, malformed receipts/duplicate keys/numeric rounding and complete
capacity retention. Full independently authored column documents compare their
nesting, code Unicode/whitespace, opaque metadata, membership and split. An
unpaired original native UTF-16 buffer reopens exactly from the private archive;
malformed private field types are rejected. Network/JNI Unicode failures never
substitute replacement text. Capacity injection is separate from the prior exact
8 MB native-server/browser byte-edge campaign.

The actual HTTP fixture first authors and saves in one Android process, then
stops the relay. A different process opens without credentials, authors offline
and saves again. After server restart, another process rejoins; further separate
processes Undo/Redo twice while retaining peer appearance and stored column split.
Every complete expected document is independently specified. The final persisted
relay document is checked through a fresh native Swift session. Five distinct
PIDs and original phase reports are in `real-http-targeted-receipt.json`.
Presence is ephemeral after restart. These are protocol/storage/native transport
checks, not physical keyboard/touch/assistive acceptance.

The local runtime is a new headless API35 arm64 emulator, Google image revision 9
and emulator 37.2.12, with a separate AVD directory and ADB server. Command-tools
19.0, Gradle 8.11.1, NDK r30 and the matching official Swift 6.4 build were used.
Google's macOS command-tools checksum and all relevant local identities are
recorded. This local row does not replace the three pinned Linux CI runtime rows.
The reference library/app and real test APK were built with these native files;
no private registry publication occurred.

## Retained failures

`compile-initial.log` retains the delegated connection property's JVM setter
collision. `compile-connection-state.log` passes after separating its observable
backing state from the public setter.

`host-initial.log` retains eight passed cases and one failed malformed-number
case: Android JSONObject's number formatter rounded `1.0000000000000001` to `1`
before Swift admission. Exact BigDecimal/BigInteger tokens now reach Swift.
`host-exact-numbers.log` passes all nine, while `json-exact-numbers.log` retains
six passed cases and signed-zero loss in default decoding/defensive copying.
That path now preserves the original negative zero. The earlier derived
JSONTokener expectation had normalized it; the corrected assertion uses the
independently specified original `-0.0`, with unchanged corpus documents.
`host-final.log`, `json-final.log` and `typed-modern.log` pass all seventeen.

`real-http-initial.log` and its receipt retain a successful Android seed followed
by failed host peer setup: appearance lacked the existing captured document
target. The target was corrected and applied status is checked.
`real-http-targeted.log` and all five proofs pass on the corrected source.

The earlier PR candidate's required API26 CI job
[115591837864](https://github.com/seventwo-studio/block-editor/actions/runs/38483605907/job/115591837864)
failed during the legacy installed-LatinIME soft-break scenario. Its original
instrumentation log contains test-start status with no completed result; guest
logcat begins with fresh init/SELinux startup at that failure time. This supports
an execution interruption, not a passed editor assertion, and does not establish
the restart's cause. Original sanitized job output, instrumentation, logcat and
emulator log are preserved here; original raw log/artifact bytes remain in the
owned build directory. Other older jobs are separately qualified in their
exact-head receipts. This required failure is not waived or counted as passed.

## Reproduction and outstanding acceptance

Use the built APK with the explicit process runner:

```sh
bun scripts/test-modern-android-relay.ts --sdk <sdk> --serial <owned-emulator> \
  --adb-port <owned-adb-port> --apk <built-test-apk> --output <new-directory>
```

The existing CI now builds the matching host Swift bridge and exercises the
modern JNI host/codec and real HTTP/process workflows on each Android row.
Fresh current-head CI/review, all complete feature interactions and rendered
acceptance, physical/assistive campaigns, long-document performance, all-runtime
private clean installation and explicit final acceptance remain open. Physical
device/final-review availability remains deferred; no requirement is waived.
The published private 0.2.0 artifacts are unchanged. Repaired delivery requires a
new reviewed version with matching artifacts and concrete approval.
