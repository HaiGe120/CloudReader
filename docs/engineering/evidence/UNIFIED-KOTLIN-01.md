# Android / Windows / Linux convergence — 2026-10-31

Status: integration verification; coordinated target-OS packages pending.

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

Latest local gates and coordinated CI results are recorded below when complete.
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
