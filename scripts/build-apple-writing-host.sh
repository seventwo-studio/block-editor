#!/bin/bash
# Source-qualified macOS acceptance host; build-only under the coordinator slot.
set -euo pipefail
TASK_PROTOCOL="${1:?Pass explicit protocol4,5 or6}"
TASK_EVIDENCE="${2:?Pass absolute, issue-owned evidence directory}"
TASK_EXPECTED_TREE="${3:?Pass exact reviewed source tree}"
TASK_ACTION="${4:---build}"
case "$TASK_PROTOCOL" in 4|5|6) ;; *) exit 2;; esac
case "$TASK_EVIDENCE" in /*) ;; *) echo 'Evidence directory must be absolute' >&2; exit 2;; esac
case "$TASK_ACTION" in --build) ;; *) exit 2;; esac
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
test "$(git write-tree)" = "$TASK_EXPECTED_TREE"
git diff --quiet
TASK_SWIFT="${SWIFT_BIN:-/usr/bin/swift}"
TASK_SWIFTC="${SWIFTC_BIN:-/usr/bin/swiftc}"
TASK_BUILD="$TASK_ROOT/.build/writing-acceptance"
TASK_APP="$TASK_BUILD/MacWritingInput-v$TASK_PROTOCOL.app"
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TASK_ARCH="$(uname -m)"
mkdir -p "$TASK_BUILD" "$TASK_APP/Contents/MacOS" "$TASK_EVIDENCE"
"$TASK_SWIFT" build --target BlockEditorApple --jobs 2 --scratch-path "$TASK_BUILD/package" \
  > "$TASK_BUILD/library-build.log" 2>&1
TASK_PRODUCTS="$("$TASK_SWIFT" build --show-bin-path --scratch-path "$TASK_BUILD/package")"
"$TASK_SWIFTC" -swift-version 6 -parse-as-library -target "$TASK_ARCH-apple-macosx26.0" \
  -sdk "$TASK_SDK" -I "$TASK_PRODUCTS" "$TASK_PRODUCTS/BlockEditorCore.o" "$TASK_PRODUCTS/BlockEditorApple.o" \
  tests/AcceptanceHosts/MacWritingInput.swift -o "$TASK_APP/Contents/MacOS/MacWritingInput" \
  -framework SwiftUI -framework AppKit > "$TASK_BUILD/host-build.log" 2>&1
# Recheck exact staged/working source after compilation; builds cannot qualify
# a changed or untracked source as the previously reviewed tree.
test "$(git write-tree)" = "$TASK_EXPECTED_TREE"
git diff --quiet
python3 - "$TASK_APP" "$TASK_PROTOCOL" "$TASK_EVIDENCE" "$TASK_EXPECTED_TREE" "$TASK_SDK" "$TASK_PRODUCTS" <<'PY'
import hashlib,json,pathlib,plistlib,subprocess,sys
app=pathlib.Path(sys.argv[1]);version=int(sys.argv[2]);directory=pathlib.Path(sys.argv[3]);tree=sys.argv[4];sdk=sys.argv[5];products=pathlib.Path(sys.argv[6])
plist={"CFBundleExecutable":"MacWritingInput","CFBundleIdentifier":f"studio.seventwo.blockeditor.writing-acceptance.v{version}","CFBundleName":f"Shared writing v{version} acceptance","CFBundlePackageType":"APPL","CFBundleVersion":"1","CFBundleShortVersionString":"1.0","LSMinimumSystemVersion":"26.0","NSPrincipalClass":"NSApplication","NSHighResolutionCapable":True,"WritingAcceptanceProtocol":version,"WritingAcceptanceDirectory":str(directory),"WritingAcceptanceSourceTree":tree}
with (app/'Contents/Info.plist').open('wb') as stream:plistlib.dump(plist,stream)
paths=[app/'Contents/MacOS/MacWritingInput',products/'BlockEditorCore.o',products/'BlockEditorApple.o']
receipt={"sourceTree":tree,"sourceCommit":subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),"protocol":version,"sdk":sdk,"runtime":subprocess.check_output(['sw_vers'],text=True),"artifacts":[{"path":str(p),"rawBytes":p.stat().st_size,"sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths],"qualification":"Compiled app and exact reviewed staged source. SourceCommit may predate staged tree; no currentCI/device/input/a11y acceptance claim."}
(directory/f'build-v{version}.json').write_text(json.dumps(receipt,indent=2)+'\n')
PY
printf 'Built source-qualified host: %s\n' "$TASK_APP"
