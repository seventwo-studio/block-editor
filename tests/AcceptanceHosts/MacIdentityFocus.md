# Mac full-view focus acceptance

`MacIdentityFocus.swift` is a standalone engineering host, outside the package
test targets. It imports the reusable Apple library. It never synthesizes text,
selection, marked text or keyboard events. Computer Use supplies all UI input.

The host starts two V2 peers with LEFT and RIGHT toggles. ORIGINAL begins under
LEFT. Its toolbar schedules a remote shared-command transaction after 45 seconds:
move the original node to RIGHT, then insert a new REPLACEMENT node with the old
public label under LEFT. Local changes made in the meantime remain independent.
The incoming batch uses the ordinary native remote-receive lifecycle.

Compile and link against the issue-owned `.build/native` Apple/Core products.
Package the binary in an issue-owned `.build/focus-acceptance` app bundle. Its
Info.plist must set `ST45FocusEvidenceDirectory` to an issue-owned state folder
and `ST45LibrarySourceTree` to the exact measured library tree. Each launch creates
a fresh isolated document and evidence subdirectory. Existing editor drafts and
earlier acceptance snapshots are never loaded or overwritten.

## Prepared commands (not yet run)

Use the approved Swift 6.4 toolchain; do not download another copy. From the issue
checkout, run the focused component test with private caches:

```sh
swift test --scratch-path .build/native --cache-path .build/native/cache \
  --config-path .build/native/config --security-path .build/native/security \
  --manifest-cache local \
  --filter fullEditorViewPreservesFocusedOriginAfterRemoteReparentAndLabelReuse
```

Build the host with that same toolchain after a compiler reservation:

```sh
ST45_PRODUCTS="$PWD/.build/native/out/Products/Debug"
ST45_APP="$PWD/.build/focus-acceptance/ST45FocusAcceptance.app"
mkdir -p "$ST45_APP/Contents/MacOS" .build/focus-acceptance/modules
swiftc -parse-as-library -target arm64-apple-macosx26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$PWD/.build/focus-acceptance/modules" \
  -I "$ST45_PRODUCTS" -L "$ST45_PRODUCTS" \
  -lBlockEditorApple -lBlockEditorCore -framework AppKit -framework SwiftUI \
  tests/AcceptanceHosts/MacIdentityFocus.swift \
  -o "$ST45_APP/Contents/MacOS/MacIdentityFocus"
python3 - "$ST45_APP" "$PWD/.build/focus-acceptance/state" <<'PY'
import plistlib, sys
from pathlib import Path
plist = {
    'CFBundleExecutable': 'MacIdentityFocus',
    'CFBundleIdentifier': 'studio.seventwo.blockeditor.st45-focus-acceptance',
    'CFBundleName': 'ST45FocusAcceptance', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'LSMinimumSystemVersion': '26.0',
    'ST45FocusEvidenceDirectory': sys.argv[2],
    'ST45LibrarySourceTree': '26dd81c1910928f85c3e28e7a9d0feb2b09d690e',
}
with (Path(sys.argv[1]) / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(plist, output)
PY
```

The source-tree value above identifies the accepted PR #40 library. Verify the
compiled library sources match it; update the value if using a later library.
Launch and interact with the bundle through Computer Use after successful capture
and exclusive foreground access. These commands are prepared instructions, not
build or acceptance evidence; this follow-up remains uncompiled.

The intended workflow is:

1. Verify successful Computer Use capture, then focus ORIGINAL and set a caret or
   selection. Schedule the move and return focus to ORIGINAL before the timer.
2. Type a distinguishable prefix, or initiate an actual system input composition.
   Record the native marked-text state while composition is active.
3. Observe acceptance or deferral of the remote batch through the full editor.
   After commitment, ORIGINAL must be under RIGHT and REPLACEMENT under LEFT.
4. Continue typing without manually refocusing. Verify that the original origin
   receives the input, that replacement text stays intact, and that selection and
   marked text behave correctly. Record any focus loss as a failure.

The host's `latest-state.json`, full accepted snapshot and `events.jsonl` report
its own original/replacement origins, text, location, native first responder,
selection and marked-text range. These are supplementary diagnostics. They do
not substitute for successful capture or actual interaction, and do not establish
VoiceOver, every Unicode/atomic-reference case, other platforms or OS 26 runtime
acceptance. When capture is blocked or the Mac is locked, stop UI input and retain
the row as open.

`NativeFocusTransferTests.swift` separately tests logical focus and subsequent
editing in an offscreen NSWindow. It never orders or activates that window. Its
component result must be recorded separately from this real input workflow.
