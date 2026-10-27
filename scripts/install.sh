#!/usr/bin/env bash
set -euo pipefail
notch_root="$(cd "$(dirname "$0")/.." && pwd)"
notch_archive="$notch_root/dist/NotchCrew-macOS-arm64.zip"
[[ "$(uname -s)" == Darwin ]] || { echo 'Error: NotchCrew requires macOS.' >&2; exit 1; }
[[ -f "$notch_archive" ]] || { echo 'Error: run ./setup.sh first.' >&2; exit 1; }
[[ ! -e /Applications/NotchCrew.app ]] || { echo 'Error: /Applications/NotchCrew.app already exists. Quit it and move it to the Trash before installing this build.' >&2; exit 1; }
notch_stage="$(mktemp -d -t notchcrew-install)"
trap 'rm -rf "$notch_stage"' EXIT
ditto -x -k "$notch_archive" "$notch_stage"
codesign --verify --deep --strict "$notch_stage/NotchCrew.app"
ditto "$notch_stage/NotchCrew.app" /Applications/NotchCrew.app
echo 'Installed /Applications/NotchCrew.app. Open it in Finder when ready.'
echo 'Hooks and login items are optional and were not installed.'
