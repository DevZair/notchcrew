# Security and privacy

## Reporting a vulnerability

Please do not post secrets, clipboard contents, permission requests, or private session logs in public issues. If private vulnerability reporting is enabled, use the repository's **Security → Report a vulnerability** page. Otherwise open a minimal issue asking for a private reporting channel, without exploit details or personal data. There is currently no guaranteed response time or published support window.

## Local data boundaries

NotchCrew observes local provider sessions and optional hook events. It does not upload that content or use a hosted backend. Session titles can contain sensitive text and may be visible on screen.

Clipboard history persists under `~/Library/Application Support/NotchCrew/Clipboard/`. The app uses private local file permissions and bounds history size, but it does not encrypt the history itself. Concealed/confidential pasteboard types are skipped; applications that do not mark secrets can still leave capturable text. Pause collection or clear history as needed. Do not commit this directory, local notes/preferences, or real session logs.

Optional hook installers change local provider hook configurations, preserve backups, and do not alter permission policies. Review a request before allowing it. Notification approval actions require macOS authentication; stale or unsupported requests must not become actionable. Never weaken these checks to make a demonstration work.

## Distribution and dependencies

Builds use an ad-hoc signature and are not Apple-notarized. Download from this repository's Releases page and compare the provided SHA-256 checksum. The bundled media helper uses a private system media adapter; its provenance and BSD terms are retained in `vendor/MediaControl/`. It may require updates after macOS changes.
