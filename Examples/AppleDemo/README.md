# Apple editor lab apps

These app targets host the shared editor on iOS/iPadOS, watchOS, tvOS, and visionOS.
Choose **Open local document** for standalone file storage or **Open collaborative
lab** for the loopback relay described in [the sync lab](../../docs/local-sync-lab.md).
They are development examples; no signing team, publication, or consumer app is configured.

Generate the project with XcodeGen 2.40 or later:

```sh
xcodegen generate --spec Examples/AppleDemo/project.yml
xcodebuild -project Examples/AppleDemo/EditorLab.xcodeproj \
  -scheme EditorLab-iOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/apple-demo CODE_SIGNING_ALLOWED=NO test
```

Use `EditorLab-watchOS`, `EditorLab-tvOS`, or `EditorLab-visionOS` with the corresponding
simulator destination to build those apps. All targets retain OS 26 minimums.
The iOS scheme supports both iPhone and iPad. Generated projects and property lists
are ignored; edit `project.yml` and regenerate them.

The iOS UI test creates an isolated local file, types through the native text view,
terminates and relaunches the app, then checks restored text and undo/redo. It uses
no relay. A debug-only UUID environment value selects the test file; release builds
ignore it. Simulator UI automation does not replace real IME, VoiceOver, external
keyboard, or device acceptance.

Run standalone, rich-block, layout and collaborative UI tests against an isolated relay:

```sh
bun run test:apple:ui 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The runner builds the Swift relay engine, generates the app project, creates a
temporary loopback server with a fresh token, and cleans it up after Xcode exits.
Pass additional destinations to run the suite on iPad too. The collaborative test
types while disconnected, merges a separate native client's edit on reconnect,
checks author-specific undo, then terminates and restores the saved draft without
a token. It also checks server acknowledgment and the participant count. A rich-block
fixture verifies editing a table cell, a toggle child and a nested list item, collapsing
and expanding the toggle, then restoring those edits after restart. The layout test
verifies that a wrapped paragraph grows to fit its text and restores its height after
restart. All tests retain screenshots in their Xcode result bundles. The runner disables verbose
simulator diagnostic collection, which can stall after tests finish; assertion
failures, test logs, result bundles, and screenshots are retained. Running
`xcodebuild test` directly skips the collaborative case when relay configuration
is absent.

The collaborative lab uses HTTP loopback networking. App Transport Security permits
local networking only; no arbitrary-load exception or production backend is added.
Physical devices need an explicit local forwarding setup and a signing team chosen
by the host. The relay continues to bind only to `127.0.0.1`.
