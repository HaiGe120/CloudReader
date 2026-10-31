# Changelog

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
