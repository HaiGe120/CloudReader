# Google connection and settings readability repair — 2026-11-01

Status: implementation and isolated Android/desktop checks passed. **Not released;
Windows/Linux target-OS checks, live Google authorization and Google Cloud setup
are not complete.**

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
existing project. No client, branding, consent status, account permission, billing
setting or existing grant has been changed. Browser control then encountered a
user tab change to an unrelated credential manager; the safety check blocked a
stale click. Further browser changes await the owner bringing the Google Cloud
tab forward and confirming continuation. No alternative route was used to bypass
that rejection. Existing Rclone settings and library data are untouched.

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
- Four collector tests, authored whitespace checks and 29 local documentation
  links passed. The eight unrelated tracked diffs still match the starting bytes.
- Windows/Linux coordinated CI with real bundled-runtime light/dark settings
  screenshots is pending. Live Google sign-in, refresh and backup are unverified.

Final logs are `android-final-build.log`, `desktop-final-build.log` and
`android-final-ui.txt` under `Build/AuthReadability/2026-11-01/`. Complete settings
screenshots are under `android-screenshots/cache/auth-readability/` as
`real-settings-dark.png` and `real-settings-light.png`; older failed diagnostic
runs are retained separately and are not the final result. The emulator uses
a new temporary data directory, not the owner's existing AVD/library. No package
has been published and the existing 1.2.0 release assets are unchanged.
