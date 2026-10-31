# Android, Windows and Linux application convergence

Assigned 2026-10-31: replace the independent Android/desktop feature paths with a
shared Kotlin application using the **current iOS** feature set as the reference,
and produce the three platform packages together from one revision.

## Scope and ownership

One integration owner, sequential implementation and checks. Preserve Android's
Room v1 database, application ID, preferences, credentials and imported originals;
preserve the desktop prototype's local library. No Apple production files are owned.
Baseline archive, tracked patch, status and source hashes are preserved under
`/tmp/cloudreader-unified-20261031/`. Historical duplicate files stay on disk;
exclude them from Kotlin compilation rather than deleting unexplained work.

| Child | Owned paths | Acceptance |
| --- | --- | --- |
| U01 | `Packages/CloudReaderKotlin/build.gradle.kts`, Kotlin core model/application/reader sources and tests | One portable model and shared feature policies; deterministic tests; exclude stale copies |
| U02 | `Packages/CloudReaderUI/`, Android library/root adapters, desktop UI/build wiring | Same responsive library/navigation/components compiled for Android and desktop |
| U03 | Shared publication preparation; Android format host/manifest and desktop reader hosts | TXT/PDF/EPUB/FB2/CBZ load, navigation, appearance, resume; malformed files fail safely |
| U04 | Desktop repository/services/settings and shared assistant/sync services | Durable imports, favorites/deletions/chats; explicit context consent; provider errors visible |
| U05 | Root packaging scripts, `.github/workflows/`, version metadata, platform packaging files | APK/MSI/DEB share a version/revision; aggregate output requires every platform job to succeed |
| U06 | Isolated tests and task evidence | Report actual unit/build/UI results and remaining OS/device validation separately |

## iOS reference and platform capabilities

Shared scope: offline library, import copies, search, favorites, continue reading,
deletion confirmation, TXT/PDF/EPUB/FB2/CBZ, reading appearance and hidden controls,
local resume, optional multi-destination v1 sync, remote assistant protocols,
conversation history and explicit book-context consent.

MOBI/AZW3 and CBR are currently gated on iOS and are not required to claim matching
its enabled readers. Apple FoundationModels, Siri and iCloud document integration
are Apple capabilities; other systems use remote AI and native file/folder access.

The existing native Android readers remain platform adapters. Windows and Linux
share the desktop host. Shared Compose source is compiled against each platform's
Compose artifacts, avoiding Android dependencies in the portable core.

## Delivery and validation

Coordinated delivery means one workflow/revision/version and a final artifact
collection that is created only after Android, Windows and Debian jobs succeed.
Windows MSI must be packaged on Windows; Linux DEB on Debian. A Mac host cannot
produce or validate those installers. Distribution signing credentials and public
publication are separate channel concerns.

Status: U01–U05 implemented; U06 coordinated **preview delivery verified** on
2026-10-31. Run `41186055676` passed core, Android, Windows, Debian and final
collection for compiled revision `06132a50c268f9b6a7a8681d0e8d07e5eacbe16e`.
The downloaded APK/MSI/DEB passed independent SHA-256 checks in
`Build/Deliveries/CloudReader-1.2.0/`. Local gates, target-OS runtime evidence
and explicit feature/acceptance gaps are recorded in
[UNIFIED-KOTLIN-01](evidence/UNIFIED-KOTLIN-01.md). This is a convergence preview,
not an assertion that every iOS feature or target-device acceptance gate is done.

The public prerelease subsequently pinned a common Windows/Linux runtime
and regenerated all three packages without changing application code. It was
published on 2026-10-31 as `v1.2.0-unified-preview`. Its
compiled revision, release URL and publication checks are tracked separately in
[OPEN-SOURCE-RELEASE-01](evidence/OPEN-SOURCE-RELEASE-01.md); the original local
checkpoint and its hashes above remain historical evidence, not the new downloads.
