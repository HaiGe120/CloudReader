# Android / Windows / Linux convergence — 2026-10-31

Status: coordinated **1.2.0 convergence preview delivered and verified**.
Full iOS feature/visual parity and production acceptance remain incomplete.

## Preserved baseline and scope

Branch: `codex/unified-android-desktop-20261031`, based on `cd90c96`.
The baseline archive, tracked patch, status and hashes are retained in
`/tmp/cloudreader-unified-20261031/`. Required pre-existing Android source, Room
schema and isolated tests are included in this integration checkpoint so a clean
CI checkout can build; they are not all new work from this assignment. Existing
Apple modifications and unexplained historical duplicates remain untouched.
Comparison with the saved baseline confirmed the seven tracked Apple diffs were
unchanged. No user library or personal sync destination was used for testing.

Owned scope: the U01–U06 path lists in `../UNIFIED_KOTLIN.md`, coordinated build
scripts/workflows/version metadata, related Android baseline dependencies and
this evidence. Schema v1, application IDs, preference/credential keys, SDK
minimums and original imported files are preserved.

## Feature distribution

| Capability | Android | Windows / Linux |
| --- | --- | --- |
| Library/search/favorites/continue/delete confirmation | Shared Compose UI; Room persistence | Same Compose UI; legacy-compatible file persistence |
| Imports | System picker, SEND/SEND_MULTIPLE/VIEW | Native file picker, file arguments, file drops and package associations |
| TXT | Native Compose host, existing UTF-16 local anchors | WebKit reflow; legacy UTF-16 offsets retained |
| EPUB | Readium, local locator, selection/appearance | Shared safe preparation; native WebKit chapters/reflow/selection |
| FB2 | Shared preparation + WebView reflow | Same preparation + native WebKit |
| PDF | AndroidX PDF, wide two-page view, text selection | PDFBox, wide facing pages, selected-glyph overlay, bounded rendering |
| CBZ | Bounded decode, zoom/pan/swipe, adaptive spreads | Bounded decode, scrollbars/zoom, adaptive spreads |
| Appearance | Existing native readers plus shared FB2/CBZ controls | Shared controls: font, size, palette, page/spread/reflow where supported |
| AI | Three remote protocols, consent, cancellation/retry/history/share | Same remote transport/shared chat UI; consent/history/cancel/retry |
| Book AI context | Bounded TXT/PDF context or reader-selected text | Consent-time bounded TXT/PDF/EPUB/FB2 text or reader-selected text |
| Sync | Existing Room/provider adapters; shared portable model/coordinator | Folder, Google appDataFolder, Dropbox, pCloud, HTTPS WebDAV, pinned SFTP adapters |
| Secrets | Existing Android Keystore behavior | Windows Credential Manager / Linux Secret Service; session-only if unavailable; disclosed plaintext fallback only after opt-in/restart |
| Output | Debug APK | Unsigned Windows MSI / Debian DEB with bundled runtime |

MOBI/AZW3/CBR stay storage-only, matching the currently gated iOS readers.
Apple Foundation Models, Siri and iCloud document integration are Apple-only;
there is no new CloudReader backend/account service.

## Repairs found during verification

- Shared reader controls use a compact two-row layout rather than crowding the
  title or hiding actions on a 360dp reader.
- Restore legacy TXT/source anchors only once the native web viewport has a
  usable layout; keep a pending restore across initial resize/configuration.
- Map portable progress to the correct EPUB/FB2 chapter, comic page and PDF page.
  PDF fractions follow the existing Apple/Android one-based page convention.
- Invalidate stale desktop-only anchors when incoming progress changes, but keep
  them for favorite-only updates. Refresh desktop library/chat state after sync.
- Preserve odd final pages in facing-page layouts. PDF typography/ink remains
  fixed while its surrounding canvas is themed.
- Keep Swing look-and-feel initialization out of the JavaFX thread to avoid a
  startup deadlock. Package required JVM modules and test the bundled launcher,
  not just the full developer JDK.
- Windows build output paths are normalized before passing them to Java through
  environment variables. The older desktop-only workflow remains manual so it
  does not emit a second, unrelated delivery on every change.

## Verification

Local checks run sequentially using JDK 17, two workers, a 2GB build heap,
in-process Kotlin compiler and no persistent build daemon. Generated files are
redirected away from the synchronized source checkout.

Local gates at the delivery checkpoint:

| Gate | Actual result |
| --- | --- |
| Shared Kotlin core | 20 tests, no failures/skips |
| Desktop repository/context/native-reader tests | 15 tests, no failures/skips on the Mac development host |
| Android JVM, lint, APK | 121 tests, no failures/skips; lint and debug assembly passed |
| Android isolated emulator | 29 tests, no failures/skips; API 37 ARM64, also tested the compact 360dp shared toolbar |
| Collector rejection/aggregation tests | 4 Python tests passed |
| Bundled Mac development runtime | Real PDF render and WebKit load/page turn passed |
| Interactive UI review | Android compact/wide library and TXT screenshots inspected; desktop reader page 1→2 and reader→assistant checked through accessibility in an isolated development copy |

Desktop native tests cover real PDF text selection, PDF facing pages/odd final
page, legacy TXT resume, EPUB page turns and reflow. Android's shared WebView
test also queues competing reflow/restore callbacks to guard against stale
callbacks resetting the requested passage. The temporary Android emulator was
shut down after testing to reclaim its memory. A hidden Mac review window could
not provide a usable whole-window screenshot; this is not counted as a full
desktop visual/accessibility acceptance matrix.

Initial coordinated CI proved Windows tests and MSI packaging; its delivery gate
correctly blocked collection because the SDK setup requested obsolete `tools`,
the container attempted an unnecessary Git ownership-sensitive revision lookup,
and the packaged-launcher check needed an explicit app-image build. Those setup
issues were repaired. Final coordinated results are appended after verification.

### Final coordinated delivery

GitHub Actions run `41186055676` completed successfully on 2026-10-31 at
08:55:47 UTC (16:55:47 Asia/Shanghai). The core, Android, Windows, Debian and
collection jobs all passed. Compiled revision:
`06132a50c268f9b6a7a8681d0e8d07e5eacbe16e` on
`codex/unified-android-desktop-20261031`. Subsequent delivery-documentation
commits are not the compiled revision and do not change these packages.

| Final target-OS gate | Actual result |
| --- | --- |
| Android Linux-hosted build | 121 JVM tests, zero failures/errors/skips; lint and debug APK assembly passed |
| Windows Server 2022 x64 | 15 tests, zero failures/errors/skips, including 4 real native-reader tests; MSI and standalone bundled app built |
| Debian 12 amd64 | 15 tests, zero failures/errors/skips, including 4 real native-reader tests; DEB and standalone bundled app built |
| Windows and Debian bundled launchers | PDF render, WebKit load/page turn, actual shared-library UI and isolated-library checks all returned true |
| Windows and Debian UI review | Actual shared-library screenshots from disposable CI desktops visually inspected; neither was blank; Android compact library/reader screenshots also inspected |
| Final collection and local download | Exactly one APK/MSI/DEB, all version 1.2.0 and the same compiled revision; all three downloaded SHA-256 digests matched |

The desktop proof invokes the built app image with its bundled runtime. It does
not install the MSI/DEB or prove installer/update/file-association acceptance.
Android's 29 isolated emulator tests and screenshots were from the local build
of the final application source, not an emulator run against the downloaded
CI-signed APK. No personal account or library was used. The emulator, review app
and persistent build processes are no longer running.

Downloaded delivery folder:
`/Users/joe/Documents/CloudReader/Build/Deliveries/CloudReader-1.2.0/`.
The folder includes the original CI packages/manifests, `delivery.json`,
`SHA256SUMS`, a progress report and preserved UI/check evidence. All three
packages and that evidence are also collected in
`/Users/joe/Documents/CloudReader/Build/Deliveries/CloudReader-1.2.0-all-platforms-preview.zip`.
No public release, pull request or merge was created by this delivery checkpoint.

| Package | SHA-256 |
| --- | --- |
| `CloudReader-1.2.0-android-debug.apk` | `585175944a3d6f43e3e2fe7f75160e108ea9f94bf3500ccf90033cde6e98e615` |
| `CloudReader-1.2.0-windows.msi` | `32a2a1886988c2c047ac7d196fe7a1bedfe70383be8e0c3653abccbd1cdf43cb` |
| `CloudReader-1.2.0-linux.deb` | `abb7ddbb4c3169be4617de3b3392f708bd61dbd2c5cbfb4abea739d468991988` |

Independent Android inspection confirmed application ID
`io.github.haige120.cloudreader`, version name `1.2.0`, version code `4`, minimum
API 31 and target API 37. APK v2 signature verification passed using an Android
Debug certificate, SHA-1 `F2:9B:FE:4A:02:32:AC:BE:77:D2:13:A1:ED:44:15:30:1C:33:83:74`.
This CI debug certificate may differ from existing installations and registered
Google OAuth credentials. It is not a verified in-place update or live OAuth
artifact. Do not uninstall an existing library to work around a signature
mismatch; use the intended matching signing key for a safe update instead.
Debian control metadata confirmed `cloudreader` version `1.2.0-1`, architecture
`amd64`; the MSI identifies an x64 installer. Windows packaging is unsigned.

The final workflow emitted non-blocking action-version deprecation warnings;
local builds also warn about Gradle features that will be incompatible with
Gradle 10. All current gates passed; dependency/toolchain migration is separate
maintenance, not evidence of a current build failure.

Full logs and intermediate screenshots remain under
`/tmp/cloudreader-unified-20261031/`, outside source control.

## Remaining acceptance limits / feature gaps

- These are preview packages, not a claim of complete iOS visual/accessibility
  parity or production release acceptance. Desktop EPUB intentionally sanitizes
  publisher styles/scripts and is not a full-fidelity publisher-layout engine.
- Windows/Linux installer/update, system file associations, OS vaults, screen
  readers and broad graphics/display matrices need installed target-device
  acceptance beyond CI native-reader checks. Physical Android gestures and
  device-vendor behavior are not established by emulator tests.
- Live OAuth/refresh/server accounts, live AI calls and a real Apple↔Android↔
  desktop sync round trip were not exercised using personal credentials.
- Schema v1 remains an unconditional manifest protocol: simultaneous device
  writers can overwrite unseen changes. Two-pass fan-out and local rereads do
  not provide remote compare-and-swap or automatic conflict choice. Some desktop
  adapters use bounded in-memory transfers and blocking I/O; no streaming or
  immediate-cancellation guarantee is claimed.
- Desktop conversation sharing/export and broad library export UI are not yet
  at iOS feature acceptance. In-book annotations/CFI/conflict-choice/background
  sync remain follow-on work, not features introduced by this assignment.
- Android debug signing and unsigned Windows packaging are preview distribution
  limits; trusted production/update signing requires the intended release keys.

### Next acceptance work, in order

1. Establish stable update-signing identities and validate installation/update
   without deleting existing Android/desktop library data.
2. Exercise authorized OAuth, token refresh, OS secret stores, live AI and an
   Apple↔Android↔desktop sync round trip against isolated test accounts.
3. Complete desktop export/share and the remaining iOS visual/accessibility,
   physical-device and installed-OS acceptance matrices.
4. Address schema-v1 concurrent-writer safety through a separately coordinated
   protocol decision; do not silently change the portable schema.
