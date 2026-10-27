# NotchCrew

**Version:** 1.9.0 | **Port:** none | **Stack:** Swift/AppKit/WebKit, Python, vanilla JavaScript/Canvas

## What
A local macOS notch companion: observed agent activity, a pixel office, clipboard history, notes, media, and a timed keep-awake function. Current UI is Russian. It does not launch agents or delegate tasks.

## Quick start
```bash
./setup.sh             # Check prerequisites and build the release ZIP
./scripts/test.sh      # Run Python, JavaScript and native Swift tests
./scripts/install.sh   # Install the built app if /Applications/NotchCrew.app is absent
open /Applications/NotchCrew.app
```
Apple Silicon, Apple Command Line Tools and Python 3.10+ are required. Tests also require Node.js 20+. No package install step, web server, environment file, or Docker service is used. Complete package tested on macOS 26; earlier systems are experimental.

## Commands
```bash
./build.sh
bash -n build.sh setup.sh scripts/test.sh scripts/install.sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=source python3 -m unittest discover -s tests -p 'test*.py'
node tests/test_scene.cjs
node tests/test_scene_render.cjs
```
Build output is `dist/NotchCrew-macOS-arm64.zip` and `dist/SHA256SUMS`. Build uses ad-hoc signing, not notarization. The installer never overwrites an existing app. No automatic login item or hook installation.

## Architecture
```text
source/     Native Swift shell, local Python collector/hooks, bundled web scene
  AgentOffice.swift       App lifecycle, WebKit bridge and utility integration
  NotchController.swift   Notch/office panels and opening/closing behavior
  NotchMiniView.swift     Native tabs, clipboard preview and utility controls
  NotchCharacters.swift  Pixel characters and telemetry selection
  OfficeClipboard.swift  Bounded local persistent text/image history
  OfficeMedia.swift      Bounded helper stream and fixed playback commands
  OfficeAwake.swift      Timed IOKit power assertions
  OfficeBridge.swift     Local request validation and replies
  collector.py           Read local sessions and role definitions
  scene.js               Canvas office rendering
  scene-core.js          Layout and movement logic
  office.js              Web view state and events
vendor/MediaControl/     Bundled arm64 helper, adapter and third-party notices
tests/                   Standalone Swift, Python unittest, Node assertions
scripts/                 Local test and install commands
```
The native app starts a local Python collector, reads snapshots, and updates native views and a bundled WebKit office. Optional provider hooks exchange local requests/replies; they never automatically approve work. Media uses a bundled helper with fixed command arguments.

## Configuration and boundaries
- Local data: `~/Library/Application Support/NotchCrew/`; notes use UserDefaults.
- Existing roles: `~/.codex/agents/` and `~/.claude/agents/`; the app does not install role definitions. Office supports up to 48 role slots.
- Python runtime candidates: `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/usr/bin/python3`.
- Clipboard persistence is not encrypted. Preserve size bounds, confidential-type exclusions, private-file permissions and explicit pause/clear behavior.
- Keep telemetry honest; do not infer working status from decorative animations.
- Preserve expiry/authentication checks for permission replies. Never loosen provider permission policies to make an integration work.
- Do not capture or commit real clipboard entries, session logs, notes, usernames, tokens, or user screenshots. Use synthetic fixtures.
- Keep third-party licenses/provenance with bundled media files.
- Optional hook installation modifies user settings; do not run installers during build/tests.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). Run `./scripts/test.sh` after behavioral changes and `./build.sh` before a release. Do not claim manual UI validation or CI success unless performed.
