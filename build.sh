#!/usr/bin/env bash
set -euo pipefail
notch_root="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Error: building NotchCrew requires macOS.' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Error: the bundled media helper supports Apple Silicon (arm64) only.' >&2; exit 1; }
for notch_tool in swiftc codesign ditto xattr; do
  command -v "$notch_tool" >/dev/null || { echo "Error: $notch_tool is required. Install Apple Command Line Tools with xcode-select --install." >&2; exit 1; }
done
notch_stage="$(mktemp -d -t notchcrew-build)"
trap 'rm -rf "$notch_stage"' EXIT
notch_app="$notch_stage/NotchCrew.app"
mkdir -p "$notch_app/Contents/MacOS" "$notch_app/Contents/Resources" "$notch_root/dist"
echo 'Compiling NotchCrew…'
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework WebKit -framework UserNotifications -framework IOKit -framework ImageIO \
  "$notch_root/source/AgentOffice.swift" "$notch_root/source/NotchController.swift" \
  "$notch_root/source/NotchCharacters.swift" "$notch_root/source/NotchMiniView.swift" \
  "$notch_root/source/OfficeBridge.swift" "$notch_root/source/OfficeNotifications.swift" \
  "$notch_root/source/OfficeClipboard.swift" "$notch_root/source/OfficeAwake.swift" \
  "$notch_root/source/OfficeMedia.swift" -o "$notch_app/Contents/MacOS/AgentOffice"
cp "$notch_root/source/Info.plist" "$notch_app/Contents/Info.plist"
for notch_file in index.html office.css office.js scene-core.js scene.js collector.py claude_hook.py codex_hook.py; do
  cp "$notch_root/source/$notch_file" "$notch_app/Contents/Resources/$notch_file"
done
ditto "$notch_root/vendor/MediaControl" "$notch_app/Contents/Resources/MediaControl"
cp "$notch_root/LICENSE" "$notch_app/Contents/Resources/LICENSE.NotchCrew"
if [[ -f "$notch_root/source/AppIcon.icns" ]]; then
  cp "$notch_root/source/AppIcon.icns" "$notch_app/Contents/Resources/AppIcon.icns"
fi
# Finder metadata is not executable code and must not enter the signature.
xattr -dr com.apple.FinderInfo "$notch_app" 2>/dev/null || true
codesign --force --sign - "$notch_app/Contents/Resources/MediaControl/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign - "$notch_app"
codesign --verify --deep --strict "$notch_app"
ditto -c -k --keepParent "$notch_app" "$notch_root/dist/NotchCrew-macOS-arm64.zip"
(cd "$notch_root/dist" && shasum -a 256 NotchCrew-macOS-arm64.zip > SHA256SUMS)
printf 'Built and verified: %s\n' "$notch_root/dist/NotchCrew-macOS-arm64.zip"
