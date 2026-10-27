#!/usr/bin/env bash
set -euo pipefail
notch_root="$(cd "$(dirname "$0")" && pwd)"
echo '=== NotchCrew setup ==='
[[ "$(uname -s)" == Darwin ]] || { echo 'Error: NotchCrew requires macOS.' >&2; exit 1; }
notch_python=''
for notch_candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [[ -x "$notch_candidate" ]]; then notch_python="$notch_candidate"; break; fi
done
[[ -n "$notch_python" ]] || { echo 'Error: install Python 3.10+ at /opt/homebrew/bin/python3 or /usr/local/bin/python3 so the app can find it.' >&2; exit 1; }
"$notch_python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "Error: the first Python found by the app must be Python 3.10+. Update the installation at " + sys.executable)'
printf 'App runtime: %s\n' "$notch_python"
"$notch_root/build.sh"
echo '=== Setup complete ==='
echo 'Install: ./scripts/install.sh'
echo 'Run tests (requires Node.js): ./scripts/test.sh'
echo 'AGENTS.md explains the codebase. No hooks or login items were installed.'
