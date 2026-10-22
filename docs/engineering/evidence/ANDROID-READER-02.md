# ANDROID-READER-02: reader controls and configurable Google credentials

Status: complete at the Android local gates, 2026-10-23. Live Google authorization remains unverified.

## Baseline and ownership

User-authorized scope: simplify Android reader controls using iOS as the product reference; allow user-supplied Google client ID/secret; fix observed Android reader/auth defects; publish the Android update to GitHub. This is a bounded Android repair, not execution of the engineering backlog.

The prior Android publication snapshot is `ac856c2421210c869d14e03694cacc7292f81d70` (`android-preview-2026-10-22`). The dirty main checkout and unrelated Apple changes are retained. Baseline status and integration evidence are under `/tmp/cloudreader-android-reader-20261022/`; the source baseline is recoverable from the previous publication commit. The real Git index and current checkout are not used to construct the publication snapshot.

Owned paths: Android `MainActivity`, `AssistantSettingsScreen`, `SettingsViewModel`, `GoogleDriveConnectionViewModel`, TXT/PDF/EPUB reader hosts and scoped PDF theme in `res/values/styles.xml`, new `NativeReaderChrome`, Google OAuth adapter/token client/diagnostics and related unit/UI tests; Android app version and README; this evidence file. No dependency, schema, minimum SDK, Apple project, or sync-format changes.

## Resulting behavior

- TXT uses a compact row with title/progress and reader actions. Appearance/font/color/layout controls are grouped under Aa in a native bottom sheet. Existing preference keys/defaults and selectable text are retained. The reader replaces the library surface so hidden navigation is not accessible behind it.
- TXT and PDF reading taps hide/restore chrome without consuming native scroll, swipe, selection, or zoom input. EPUB listens through Readium's handled-input chain and uses center taps, retaining edge page turns and link/selection handling. All formats have a small accessible restore control and reclaim header space while hidden.
- Facing TXT pages remap the saved source-text anchor after available reading space changes, without recursive layout measurement. Native Android 17 chrome initialization obtains the decor view before accessing its window insets controller.
- PDF URI assignment is deferred until the viewer fragment is attached; creating the fragment previously accessed its ViewModel while detached and crashed before rendering. Its native inflater uses a scoped Material 3 theme already provided by AndroidX PDF, supplying required color/typography attributes. Initial page restoration waits for the PDF view's next positive-size layout instead of a queued callback that could request zero-size bitmaps.
- Settings accepts a Web application client ID/secret, preserves an unchanged saved secret, validates before mutation, and invalidates only Google's old grant when credentials change. Saving snapshots submitted values, blocks Google Connect/selection until completion, ignores duplicate saves, and preserves newer edits. Failed/cancelled client-ID persistence restores the prior secret and leaves the working Google grant/selection intact. Credentials/refresh tokens remain encrypted and excluded from backup/shared records. Built-in native authorization remains the blank-config path.
- Custom credentials use native Google server-code authorization followed by local code exchange/renewal. Errors expose safe actionable details without arbitrary response bodies or secrets. Reconnect requires a fresh refresh grant; stale renewal responses cannot overwrite a subsequent account connection. One sync store retains its own access-token snapshot. Valid custom tokens are reused until the 30-second renewal margin and bound to the current client credentials/refresh grant.

## Google configuration boundary

No Google Cloud client was created. The prepared client form was not submitted after the user chose runtime credentials instead. No personal client secret is bundled.

Web credentials must belong to the project owning the installed package/signing certificate's Android OAuth registration. Android OAuth clients do not have secrets. Google allows a package/SHA-1 pair in only one project; unrelated users' projects cannot all register the same distributed APK. Settings explains this and displays the installed package/SHA-1 for copying. A separately signed build needs its own registration. [Google's uniqueness rule](https://support.google.com/firebase/answer/6401008?hl=en).

Google documents server-code/refresh-token exchange as a backend operation. This configurable client performs the exchange locally with user-supplied, encrypted credentials; it does not introduce a backend or embed shared developer credentials. [Authorization guide](https://developer.android.com/identity/authorization), [native code exchange parameters](https://developer.android.com/identity/legacy/gsi/offline-access).

Error 8 is reported as an internal provider error with stage and sanitized detail, not declared proof of SHA-1 mismatch. A native account picker is not evidence of a completed Google grant. No successful real Google authorization or live provider sync was verified.

## Validation

The final JVM/build gate passed **107 unit tests**, with **0 lint errors / 27 warnings**, debug APK and instrumentation APK assembly. The configured SDK remains API 37, minimum API 31; version is 1.0.1 (code 2). Packaged APK ZIP integrity and the unchanged debug signer passed. SHA-256: `fcde879a5f21d5c4de21577121399295a889356f57bb373be5030eb4047ccb8a`.

Device gates:

- Android 17/API 37 emulator, 1840×2208 at 420 dpi: **24/24 connected tests passed**. These include document imports/cancellation, isolated storage/sync integration, native hide/restore, TXT appearance/back behavior, native scrolling/selection, facing-page navigation with source-anchor preservation, and actual rendering of a temporary three-page PDF before/after fragment-state restoration.
- Same isolated emulator at 1080×2092, 420 dpi: **5/5 targeted reader tests passed**, covering the TXT, native chrome and PDF lifecycle classes.
- Manual EPUB smoke: center hide releases header space, restore works, edge tap advances while hidden, and the current reading passage remains after restoration.
- Manual PDF smoke: an imported fixture opens, renders and expands from content top 200 px to 0 px when hidden.
- Manual TXT smoke at compact dimensions: compact header, center content-tap hide/restore, native text top 210→21 px while hidden, full Aa appearance sheet, and a real long-press selection with handles and the Copy/Ask CloudReader/Share/Select all menu.
- Settings UI smoke: both Google fields are present, the secret field has password semantics, and the setup dialog shows the installed package/SHA-1 plus the same-project/unique-registration requirement. No real credentials were entered.

A new token-client assertion was corrected to inspect the entire exception report (including coroutine-recovered causes), preserving the requirement that credentials/response bodies never leak. The TXT native-selection gesture test now waits for an actual ScrollView fling to stop and validates that its press coordinates resolve to a real visible word; the assertion still requires native TextView selection. The PDF regression uncovered and verified the attachment, theme and page-restore timing repairs. Early interrupted/failing attempts are not counted as successful gates. All final production sources were frozen before packaging.

Validation uses fresh Android 17/API 37 emulator data, generated local fixtures, temporary test storage and isolated preferences/databases. No personal library, Google account or remote sync destination is used. A 1840×2208, 420 dpi viewport approximates unfolded screen dimensions only; it does not prove physical Pixel Fold posture/hinge behavior.

Local build output is redirected through a temporary Gradle init script to `/tmp/cloudreader-android-reader-20261022/gradle-build`. This avoids recurring duplicate generated resource/class files in the synced Documents build directory; no permanent project build paths are changed. The interrupted in-place build is not counted as a successful gate.

## Remaining limits

Real Pixel Fold interaction, real Google credentials/consent/code exchange/refresh, provider sync and physical fold/hinge transitions need device validation. EPUB process-death reopening remains an existing follow-up; this task preserves the current reader's saved progress behavior and does not replace its publication lifecycle.
