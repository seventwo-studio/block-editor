#!/usr/bin/env bash
set -euo pipefail

prototype=false
if [[ "${1:-}" == --prototype ]]; then prototype=true; shift; fi
mode="${1:-run}"
case "$mode" in run|--build-only|--verify|--debug|--logs) ;; *) echo "usage: $0 [--build-only|--verify|--debug|--logs]" >&2; exit 2 ;; esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
package_root="$root"
product_name="local-editor-app"
app_name="LocalEditorLab"
bundle_id="studio.seventwo.blockeditor.local-lab"
if [[ "$prototype" == true ]]; then
  package_root="$root/Examples/ModernInteractionPrototype"
  product_name="ModernInteractionPrototype"
  app_name="ModernInteractionPrototype"
  bundle_id="studio.seventwo.blockeditor.st121.mac"
fi
app="$root/.build/$app_name.app"
binary="$app/Contents/MacOS/$app_name"
swift build --package-path "$package_root" --product "$product_name"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build --package-path "$package_root" --show-bin-path)/$product_name" "$binary"
if [[ "$prototype" == true ]]; then
  mkdir -p "$app/Contents/Resources"
  cp "$root/Examples/AppleDemo/Fixtures/rich-blocks.json" "$app/Contents/Resources/rich-blocks.json"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$app_name</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>$app_name</string>
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
  exec /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
fi
