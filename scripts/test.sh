#!/usr/bin/env bash
set -euo pipefail
notch_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$notch_root"
[[ "$(uname -s)" == Darwin ]] || { echo 'Error: the native tests require macOS.' >&2; exit 1; }
for notch_tool in python3 node swiftc; do
  command -v "$notch_tool" >/dev/null || { echo "Error: $notch_tool is required." >&2; exit 1; }
done
notch_stage="$(mktemp -d -t notchcrew-tests)"
trap 'rm -rf "$notch_stage"' EXIT
echo 'Running Python collector and hook tests…'
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=source python3 -m unittest discover -s tests -p 'test*.py'
echo 'Checking JavaScript and scene behavior…'
for notch_js in source/*.js; do node --check "$notch_js"; done
node tests/test_scene.cjs
node tests/test_scene_render.cjs
notch_test() {
  local notch_name="$1"
  shift
  echo "Running ${notch_name}..."
  swiftc "$@" "tests/$notch_name.swift" -o "$notch_stage/$notch_name"
  "$notch_stage/$notch_name"
}
notch_test BridgeTests source/OfficeBridge.swift
notch_test NotificationTests -framework AppKit -framework UserNotifications -framework IOKit source/OfficeBridge.swift source/OfficeNotifications.swift
notch_test NotchTests -framework AppKit -framework ImageIO -framework QuartzCore source/OfficeClipboard.swift source/NotchController.swift source/NotchCharacters.swift source/NotchMiniView.swift
notch_test AwakeTests -framework AppKit -framework IOKit source/OfficeAwake.swift
notch_test MediaTests -framework AppKit -framework ImageIO source/OfficeMedia.swift
notch_test CharacterTests -framework AppKit source/NotchCharacters.swift
notch_test MiniViewTests -framework AppKit -framework ImageIO source/OfficeClipboard.swift source/NotchMiniView.swift source/NotchCharacters.swift
notch_test ClipboardTests -framework AppKit -framework ImageIO source/OfficeClipboard.swift
echo 'All tests passed.'
