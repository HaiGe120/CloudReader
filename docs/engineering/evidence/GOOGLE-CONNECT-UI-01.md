# Google connection and settings readability repair — 2026-11-01

Status: implementation, isolated Android checks and coordinated Windows/Linux
target-OS build/runtime/UI checks passed. Google Cloud registrations were then
created and verified with the owner's approval. **Not released; live Google
authorization, deployed Desktop defaults and safe Android update signing remain open.**

Compiled revision: `3bdbcfa06666b0fe1e56879c373c9c2ceb3acb9a` on
`codex/google-connect-readability-20261101`. Coordinated run `41307122651`
completed successfully; the repository API records its final update at
2026-11-01 12:40:43 UTC (20:40:43 Asia/Shanghai). This branch does not replace
default `main`, the existing release tag or any public release asset.

## Assigned scope and preservation

The owner reported Android `UNREGISTERED_ON_API_CONSOLE` and unreadable settings
cards, asked for the Windows/Linux fixes too, and clarified that normal users
must not supply OAuth credentials. They requested help with one-time developer
configuration and chose to retain the existing Google project.

Owned paths: Android settings/Google connection model, diagnostics, OAuth adapter
and tests; shared Kotlin theme and settings components; desktop settings/OAuth,
its tests, generated public-client configuration and packaged UI checks;
coordinated workflow configuration, local OAuth-file ignore rules, platform guides, Google setup guide and this
evidence card. Apple files, the dirty implementation plan, unrelated untracked
files, schema v1, app IDs, preference/vault identifiers, dependency versions and
SDK minimums remain unchanged. The starting status and eight unrelated tracked
diffs are retained in `Build/AuthReadability/2026-11-01/`; comparison confirms
those diffs are byte-for-byte unchanged.

## Observed causes and implementation

- The old Android destination rows combined a hardcoded cream background with
  dark-mode foregrounds. New shared `SyncDestinationCard` explicitly pairs
  surface/content colors in both themes, separates actions from long labels,
  and keeps descriptions readable. Shared palette tests cover 17 text pairs.
- Android's root now uses paired theme colors and system-aware system bars.
  The AI protocol selection uses theme-aware chips with horizontal overflow.
- The explicit `UNREGISTERED_ON_API_CONSOLE` reason is distinguished from a
  generic error 8. Registration failures offer a short maintainer-oriented
  summary, optional sanitized diagnostics and copyable installed registration.
- Fresh Android settings default to native Play services authorization. Custom
  credentials are hidden in Advanced; existing custom grants are preserved by
  migration inference. Deliberately switching to standard retains the advanced
  ID/secret but invalidates only the Google grant and requests reconnecting.
- Windows/Linux use the same cards/theme and normal Connect UI. Built-in Desktop
  OAuth settings are supplied by the maintainer at build time, not by readers.
  Custom credentials remain optional. Failed connection does not optimistically
  enable the destination; Google errors are sanitized and have specific recovery.
- Desktop packaged-runtime checks now render/access the real settings screen in
  light and dark modes, with CI screenshots, in addition to library/PDF/WebKit.

## Google Cloud inspection and current boundary

Read-only inspection of the existing project confirmed an Android registration
for an **older** signing certificate, not the reported current 1.2.0 certificate.
It also confirmed that the supplied client ID is a **Desktop** client named Rclone,
not an Android-flow Web client. The existing project's consent name is Rclone.
No secret from the owner's screenshot was copied into source, logs or requests.

A separate project form was prepared but **not submitted**. The owner chose the
existing project. At that initial checkpoint, no client, branding, consent status,
account permission, billing setting or existing grant had been changed. Browser control then encountered a
user tab change to an unrelated credential manager; the safety check blocked a
stale click. A later read-only tab inventory still identified the correct Google
tab, but its browser connection was detached; no tab-specific writes were made.
Further browser changes were paused until the owner explicitly requested Chrome
control again. No alternative route was used to bypass the blocked stale click.
The subsequent approved registration work is recorded below. Existing Rclone
settings and library data remain untouched.

### Approved Google registration correction — 2026-11-01

The owner explicitly approved **Create both registrations** after reviewing the
prepared Android and Desktop forms in the existing project. Google confirmed
both creations; the client list was rechecked with both the original Android
registration and Rclone client still present.

- Android: the new registration is for package `io.github.haige120.cloudreader`
  and SHA-1 `4F:2D:16:4E:E4:43:9D:5E:6A:1F:76:F2:AF:38:EC:6A:A9:77:84:C7`.
  The published 1.2.0 APK was independently re-inspected with `apksigner`/`aapt`,
  and Google's saved client-detail fields match that APK exactly. The older
  certificate registration was not edited or deleted.
- Desktop: a separate **CloudReader Windows and Linux** client of type
  **Desktop app** was created, not a reused Rclone or Web-server credential.
  The owner downloaded its JSON; its `installed` shape, project/client identity,
  required secret and official Google endpoints were validated without printing
  the secret. The original download is retained; an owner-readable-only build
  copy is under ignored `Build/GoogleRegistration/2026-11-01/google-oauth-local.json`.
- The Google Drive API is already listed among **Enabled APIs & Services**.
  The audience is **External** with publishing status **In production**. Those
  existing settings were inspected, not changed. No API, billing, branding,
  consent-publishing or existing-client credential changes were made.
- The installed 1.2.0 app must stop using its saved Rclone Desktop credentials:
  save blank Google app-credential fields, then Connect using native authorization.
  No new Android client ID needs to be pasted into the app. This clears only the
  old Google authorization configuration, not the app's library or other providers.
- The owner reported that they **have not retried Android Connect yet**. Do not
  treat client creation, the console's last-used date or the preceding build/UI
  tests as successful account authorization. Actual Android consent/connection,
  Desktop consent/refresh and backup acceptance remain unverified. The new
  Desktop client also still needs to be supplied to the official build pipeline.

Sanitized receipts and private screenshots are under
`Build/GoogleRegistration/2026-11-01/`, including `registration-verified.json`,
`android-registration-verified.png`, `registrations-created.png`,
`drive-api-enabled.txt`, `audience-status.txt` and `desktop-config-verified.json`.
No downloaded credential file or secret is included in tracked source or logs.

The exact 1.2.0 CI signing key is not configured for reuse. The local older debug
key is a different certificate; it cannot safely update the reported installed
1.2.0 APK. Do not publish a supposed in-place Android update or tell the owner to
uninstall/clear data. Stable signing and safe migration/update acceptance remain
release gates, separate from registration and UI verification.

## Verification so far

- Android JVM: **127 tests**, zero failures/errors/skips; final lint, debug APK
  and instrumentation APK assembly passed with the complete repair source.
- Desktop local: **53 tests**, zero failures/errors, **4 native GUI skips** because
  the opt-in GUI flag was off. This is compilation/unit evidence on the Mac host,
  not Windows/Linux target-OS acceptance. It includes the final runtime harness,
  36 isolated Google OAuth tests and two shared-palette tests.
- Android disposable API 31 emulator: **6 UI tests passed**, no failures/skips:
  light/dark × 320/360dp cards at 1.5× font scale, plus the real settings screen's
  light/dark standard/Advanced flow using an injected in-memory model. Complete
  screen screenshots were visually inspected; the former white-on-white cards
  are gone, and client fields are absent from ordinary onboarding.
- Initial test failures identified intrinsic paragraph-container width reporting
  and native Android press ripples that outlive Compose idleness. Assertions now
  check actual line extents, full viewport bounds, no ellipsis/height clipping,
  and the same captured foreground/background frame after a bounded wait for
  the native ripple. Pixel thresholds and minimum **4.5:1** contrast were not
  relaxed. Four compact/large-font cases also passed twice independently;
  temporary wrong-background, low-contrast and clipping controls correctly failed
  and were removed. No personal stores or Google account were used.
- Four collector tests, authored whitespace checks and local documentation
  links passed. The eight unrelated tracked diffs still match the starting bytes.
- Coordinated CI: core, Android, Windows, Debian and final collection all passed
  for the compiled revision above. Android ran **127 JVM tests**; Windows and
  Debian ran **53 tests each**, including the four real native-reader tests, with
  **zero failures/errors/skips** on every target. APK/MSI/DEB were collected with
  one version and revision. They are validation artifacts, not a new public release.
- Both Windows/Linux bundled runtimes reported true for PDF render, WebKit load
  and page turn, actual library UI, **light settings UI**, **dark settings UI** and
  isolated-library checks. All four target-OS settings screenshots were visually
  inspected; no blank or white-on-white settings surfaces remained, and normal
  Google credential fields were absent. This is app-image/runtime evidence, not
  installed MSI/DEB, update, vault, broad display/accessibility or physical-device
  acceptance. Existing action-version deprecation warnings did not fail any gate.
- Live Google sign-in, refresh and backup remain unverified. The approved Google
  registrations and local Desktop configuration were verified after these code
  checks, but are not a deployed/bundled client or an account round trip. A safe
  public Android update also needs signing continuity; none of those gates is
  implied by client creation, compilation or rendering checks.

Final logs are `android-final-build.log`, `desktop-final-build.log` and
`android-final-ui.txt` under `Build/AuthReadability/2026-11-01/`. Complete settings
screenshots are under `android-screenshots/cache/auth-readability/` as
`real-settings-dark.png` and `real-settings-light.png`; older failed diagnostic
runs are retained separately and are not the final result. Target-OS reports and
screenshots are in `ci-windows/`, `ci-linux/` and `ci-android/`; the run receipt is
`coordinated-run-final.json`. The emulator used a new temporary data directory,
not the owner's existing AVD/library, and was shut down after the checks. No
updated GitHub release has been published; the existing 1.2.0 assets are unchanged.
