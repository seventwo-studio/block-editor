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

The collaborative lab uses HTTP loopback networking. App Transport Security permits
local networking only; no arbitrary-load exception or production backend is added.
Physical devices need an explicit local forwarding setup and a signing team chosen
by the host. The relay continues to bind only to `127.0.0.1`.
