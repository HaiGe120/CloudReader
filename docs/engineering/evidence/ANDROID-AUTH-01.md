# ANDROID-AUTH-01 — Google authorization and bounded Android audit

Date: 2026-10-22. Code and automated gates pass; successful live Google authorization remains unverified.

## Scope and preservation

User report: the native Google account selector opens, but selecting an account appears to do nothing. The user also authorized investigating and repairing other concrete Android defects. This is a bounded repair of the existing Android authentication/settings, assistant handoff, and import paths, not execution of the remaining engineering backlog.

The checkout already contained substantial tracked and untracked work. The initial full tracked diff, status, and Android source archive are retained at `/tmp/cloudreader-android-google-20261022/`. Comparison against that archive confirms production edits are limited to `MainActivity.kt`, `GoogleDriveConnectionViewModel.kt` (new), `AssistantSettingsScreen.kt`, `SettingsViewModel.kt`, `AssistantViewModel.kt`, `sync/OAuthAndCloudStores.kt`, and `data/LibraryRepository.kt`, plus focused tests and documentation. Unrelated tracked diffs match the initial checkpoint. No Apple code, manifests, dependency versions/locks, database schema, sync wire format, credential identifiers, or installed personal library was changed by this repair.

## Findings and repairs

- Google callback previously discarded every activity result other than `RESULT_OK`. It now parses all returned intents, including Google's detailed failure statuses, as in the [official authorization example](https://developer.android.com/identity/authorization). A retained ViewModel tracks pending authorization and saves the token before reporting success; duplicate requests, launch/provider errors, cancelled or missing results, and credential-write failures are handled. Settings displays a persistent result below the Google row, rather than relying on an absent or transient toast. The adapter retains Google error codes and supplies installed-package/SHA-1 information for configuration errors. The same private `drive.appdata` scope is preserved. These changes repair the silent failure boundary; they do not prove which Google-side condition caused the user's particular account-selection failure.
- Background Google token renewal no longer calls the explicit connection operation, so it cannot re-select a destination disabled by the user during a sync run.
- Saving WebDAV or SFTP with a blank password field preserves an existing saved password. Replacement passwords and subsequent saves are covered. Blank first-time setup behavior is retained; the UI explains the blank-field behavior.
- Incoming book/passage context is retained by the assistant before the parent clears its reader overlay. Sending still requires explicit context consent; selecting another chat or starting a new chat clears pending context. Unsent context survives Activity recreation through its ViewModel but is not persisted across process death.
- Import metadata-query and stream-open errors now reject only the affected document and continue the batch. Cancellation propagates, stops later documents, and cleans up partial bytes/interrupted new-row commits. A blocking provider read must return before cooperative cancellation can complete.
- Dropbox sign-in now selects its destination after credentials are saved, matching the existing Google/pCloud connection behavior. Successful pCloud reconnection clears its cached folder ID so it cannot reuse an earlier account/region's folder. These provider-specific changes passed build/source checks; live Dropbox/pCloud flows were not exercised.

## Validation

Environment: JDK 17 at `/opt/homebrew/opt/openjdk@17`, Android SDK at `/Users/joe/Library/Android/sdk`. Android 16/API 36 `medium_phone` emulator, serial `emulator-5564`, launched with a fresh temporary data directory and snapshots disabled. Existing AVD/user data was not used as the test store. Instrumentation was inspected for isolated database/file roots before execution.

An initial focused build encountered the known stale generated `cloudreader_icon 3.png` resource. Cleaning generated Android build outputs resolved it. The final integration command, from `Apps/Android`, was:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/Users/joe/Library/Android/sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_SERIAL=emulator-5564
export PATH="$JAVA_HOME/bin:$PATH"
./gradlew --console=plain testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest
```

Results: **64 unit tests and 19 connected instrumentation tests passed, 0 failures/errors/skips**. Lint passed with 35 warnings and 0 errors. Debug APK assembled and its APK signature verified. Signing SHA-1 is `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`, matching the existing documented debug certificate. Targeted whitespace checks passed.

Manual emulator smoke check: installed/launched the app, opened Settings, tapped Google Connect, reached Google's native account-add flow, and pressed Back. The app displayed Google cancellation code 16 below the Google row and left Connect enabled. The fresh emulator has no Google account. UI dumps and a screenshot are retained under `/tmp/cloudreader-android-google-20261022/`. This verifies error return and recovery, not successful account selection, token renewal against a real account, Drive API access, cross-device sync, or physical-device behavior. No Google Cloud registration was inspected or changed, so a registration problem remains a possibility rather than a confirmed diagnosis.

Installable artifact: `Build/Android/CloudReader-Android-2026-10-22-debug.apk` (same application ID/debug signing identity). This is a debug-signed preview build.

## Remaining source-review findings

These were identified by inspection and intentionally left for separate bounded repairs. They are not claimed as live reproductions:

- `EpubReaderActivity.onCreate` finishes whenever saved state exists; after process death the reader closes instead of re-opening the publication/locator. A proper Readium restoration path needs format-specific lifecycle tests.
- `LibraryRepository.removeChat` removes a chat and writes its tombstone in separate DAO operations; an interruption can omit the deletion record and allow a remote copy to reappear. Use a transactional tombstone-first operation and isolated durability tests.
- `SyncEngine` captures conversations before remote I/O and later replaces them without re-merging against the latest local row. A local chat edit during that interval can be overwritten. Repair the commit boundary with concurrency fixtures.
- `FolderStore.read` can treat a found document whose input stream is null as missing. It should distinguish an unavailable existing manifest from an absent manifest before publishing any replacement.

No claim is made that the broader Android app is defect-free. Tablet/foldable/accessibility matrices and live provider checks remain open.
