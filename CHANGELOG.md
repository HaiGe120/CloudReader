# Changelog

## 1.2.1 Google connection preview — 2026-11-01

Prerelease: `v1.2.1-google-connect-preview`; compiled source `48d8b5e154bc5b101bb85051d869836e02039069`;
[coordinated run 41315984334](https://github.com/HaiGe120/CloudReader/actions/runs/41315984334). See [release notes](docs/releases/1.2.1-google-connect-preview.md).

### Changed

- Standard Google connection requires no reader-supplied IDs/secrets. Android
  uses native authorization; Windows/Linux bundle the approved Desktop client.
- Optional Advanced settings preserve existing custom credentials/grants until
  an intentional Google mode change. Books and other provider connections stay intact.
- Shared light/dark destination colors and readable actions/descriptions;
  Android root colors/protocol chips follow theme; sanitized connection help.

### Verification and distribution

- 127 Android JVM tests in CI and local release build; lint/APK passed. Six actual
  local-APK API 31 settings UI tests passed, including 1.5× font at 320/360dp.
- 53 tests per Windows/Debian OS, 20 shared-core tests and four collector tests;
  zero failures/errors/skips. Both bundled launchers passed reader/library/settings
  checks and approved Google-default fingerprint comparison. Real screenshots reviewed.
- APK/MSI/DEB share one version/revision. Public Android APK is locally built with
  the retained older key, not CI's temporary key; no private signing key is uploaded.
- **Not an in-place update over public 1.2.0. Do not uninstall or clear data.**
  Older-preview installed update/data retention also remains untested.
- Windows unsigned; installed-OS updates, live Google consent/refresh/backup,
  physical Android, broad accessibility and full iOS parity remain unverified.
- MIT and dependency terms retained, with notices and matching runtime sources.
  Native Apple apps, schema, dependencies, SDK minimums and credential identifiers unchanged.

## 1.2.0 unified preview — 2026-10-31

Prerelease: `v1.2.0-unified-preview`. APK/MSI/DEB compiled from
`6973577172f0da70f752b8f51e76b5dc470975b0`; publication documentation may be newer.

### Added

- Shared Android/Windows/Linux library, navigation, assistant and reader controls.
- TXT/PDF/EPUB/FB2/CBZ adapters, portable progress and local resume.
- Desktop provider adapters, OAuth, durable conversations and OS secret stores.
- Coordinated APK/MSI/DEB collection gated on every platform succeeding.
- Bundled-runtime PDF/WebKit/library checks and actual UI/test evidence.
- Contribution, security, release and third-party distribution guidance.

### Fixed during verification

- Compact toolbar crowding and stale callbacks resetting restored reader positions.
- Odd facing pages, stale desktop anchors after sync, and shelf/chat refresh.
- Desktop startup deadlock, bundled JVM modules, Windows paths and Debian checks.

### Known limits

Not full iOS parity or a signed production release. Live account/AI/sync,
physical Android behavior, installer/update/accessibility matrices and desktop
export/share remain open. Schema-v1 concurrent-writer overwrite risk remains.
See [release notes](docs/releases/1.2.0-unified-preview.md) and
[detailed evidence](docs/engineering/evidence/UNIFIED-KOTLIN-01.md).

Earlier previews remain in [GitHub Releases](https://github.com/HaiGe120/CloudReader/releases).
