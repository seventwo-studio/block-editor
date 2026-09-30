#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs) ;; *) echo "usage: $0 [--build-only|--verify|--debug|--logs]" >&2; exit 2 ;; esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
app="$root/.build/LocalEditorLab.app"
binary="$app/Contents/MacOS/LocalEditorLab"
swift build --product local-editor-app
mkdir -p "$app/Contents/MacOS"
cp "$(swift build --show-bin-path)/local-editor-app" "$binary"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalEditorLab</string>
<key>CFBundleIdentifier</key><string>studio.seventwo.blockeditor.local-lab</string>
<key>CFBundleName</key><string>Local Editor Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ "$mode" == --build-only ]]; then echo "$app"; exit 0; fi
# Only stop this checkout's staged demo, never another application's editor.
pkill -f "^$binary$" >/dev/null 2>&1 || true
if [[ "$mode" == --debug ]]; then exec lldb -- "$binary"; fi
/usr/bin/open -n "$app"
if [[ "$mode" == --verify ]]; then
  sleep 1
  pgrep -f "^$binary$" >/dev/null
elif [[ "$mode" == --logs ]]; then
  exec /usr/bin/log stream --info --style compact --predicate 'process == "LocalEditorLab"'
fi
