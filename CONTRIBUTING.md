# Contributing to NotchCrew

Small, focused contributions are welcome. Useful starting points include English localization, accessibility, provider-format compatibility, and synthetic regression tests.

## Development setup

Fork the repository, clone your fork, and create a branch for one change. On an Apple Silicon Mac with Command Line Tools, Python 3.10+ and Node.js 20+:

```bash
./setup.sh
./scripts/test.sh
```

The build creates `dist/NotchCrew-macOS-arm64.zip`; install it with `./scripts/install.sh` after quitting and removing an older build. Installation does not launch the app or configure hooks. Manual UI checks require a local macOS desktop session.

## Code and testing

- Swift uses AppKit, standalone files and explicit state. Keep UI updates on the main thread; clean up timers, helper processes and power assertions.
- Python uses the standard library. Preserve bounded reads, parameterized SQLite queries, private local files, and defensive parsing of provider events.
- JavaScript uses vanilla DOM/Canvas modules. Keep rendering separate from scene state and movement logic where possible.
- Do not add fabricated status/progress. Decorative dialogue must remain separate from real telemetry.
- Preserve clipboard privacy limits and request validation. Include a regression test for behavioral fixes; do not record real user content as fixtures.
- Avoid unrelated formatting churn and dependencies without a clear benefit.

Run `./scripts/test.sh` and `./build.sh` before opening a pull request. For interface changes, attach a screenshot using synthetic tasks and clipboard data. Explain any test or platform you could not check.

## Pull requests

Describe the user-visible problem, the resulting behavior, and how you tested it. Link the related issue when one exists. Keep each PR centered on one feature or fix; discuss broad architectural changes in an issue first. Contributors retain copyright in their contributions and submit them under this repository's MIT license.

## Issues and security

For bugs, include macOS version, CPU architecture, NotchCrew version, reproduction steps, and expected/actual behavior. Remove private paths, command contents, tokens and screenshots of personal sessions. See [SECURITY.md](SECURITY.md) for vulnerabilities.

## Using Codex

Open the repository in Codex or run `codex` from its directory. [AGENTS.md](AGENTS.md) contains verified build/test commands and architecture notes. Give the agent a specific scope and review its changes, especially permission handling and clipboard persistence. Do not let an automated task change your real provider hook settings merely to run tests.
