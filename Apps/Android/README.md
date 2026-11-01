# CloudReader for Android

Native Kotlin and Jetpack Compose application. Android 12 (API 31) or newer.

## 1.2.0 coordinated preview

Download the APK or all-platform bundle from the
[unified preview release](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.0-unified-preview).
Read the [release notes](../../docs/releases/1.2.0-unified-preview.md) for exact
source/runtime provenance and acceptance limits. CI APKs are debug-signed.
Do not uninstall an existing app or delete its library to bypass a signature
mismatch; a safe update needs the original matching signing key.

## Build

Install JDK 17 and Android SDK Platform 37, Build Tools 37, and Platform Tools. Set `JAVA_HOME` to the JDK and `ANDROID_HOME` or `ANDROID_SDK_ROOT` to the SDK; an ignored `Apps/Android/local.properties` with `sdk.dir=...` is also supported by Gradle. Android Studio Device Manager or the Android CLI can create emulators. The Gradle wrapper is the supported build entry point. From the repository root, run the reproducible checks with:

```sh
./scripts/check-android.sh
```

That runs local unit tests, lint, and a debug build through `Apps/Android/gradlew`. The same checks can be run directly from `Apps/Android` with `./gradlew testDebugUnitTest lintDebug assembleDebug`. The debug APK is written to `Apps/Android/app/build/outputs/apk/debug/app-debug.apk`.

Instrumented tests are a separate device check. Connect exactly one authorized test device or emulator, get its serial from `adb devices`, then run from the repository root:

```sh
ANDROID_SERIAL=emulator-5554 ./scripts/check-android-instrumented.sh
```

Replace the example serial with the selected device. The script checks that this is the only online ADB device because Gradle's connected-device task can run against every connected device. Android's command-line test guide describes the connected test task and result locations: [Test from the command line](https://developer.android.com/studio/test/command-line).

## Google Drive setup

Normal users should only tap **Connect**, choose a Google account and approve Drive backup access. They do not need a client ID, client secret or Google Cloud project. Android uses native Google Play services authorization. The app maintainer must register the distributed package and signing certificate once. See [Google Drive connection and maintainer setup](../../docs/GOOGLE_DRIVE_SETUP.md).

The unreleased connection/readability repair hides custom credentials under **Advanced Google settings (optional)** and pairs all settings-card colors with the light/dark theme shared with Windows/Linux. Existing custom connections are preserved until the user explicitly chooses **Use standard Google connection**; that choice retains advanced credentials but requires fresh Google consent. The published 1.2.0 preview still has the older credential-heavy layout. Current repair evidence and remaining configuration/testing limits are [recorded separately](../../docs/engineering/evidence/GOOGLE-CONNECT-UI-01.md).

For optional developer/self-build configuration only, a custom **Web application** client and its secret must belong to the same project as the APK's **Android OAuth registration**. Android clients themselves do not have a secret. Enable the Drive API and configure consent/test users. A Web ID and secret alone cannot replace package/certificate registration. The secret and refresh grant remain encrypted with Android Keystore and excluded from backup/sync manifests. A blank secret retains the saved value only for the same client ID; changed credentials require reconnecting. Custom server-code exchange is an advanced compatibility path, not required for normal native authorization.

To inspect a locally built APK's certificate, run `./gradlew signingReport` and
use the `SHA1` for that variant. A CI runner's debug key can differ from a local
build or earlier preview. Use **Android registration details** in the installed
app or inspect the actual downloaded APK; do not reuse a historical certificate
fingerprint. The package remains `io.github.haige120.cloudreader`.

No developer Web client secret is bundled in Android. Successful authorization with a real Google account has **not** been verified in this repair. See [Google authorization](https://developer.android.com/identity/authorization).

Connection status remains visible below the Google row, with optional expandable diagnostics. Returned intents are parsed even when Android reports a non-OK result; errors retain sanitized provider details. Generic error 8 alone does not establish a registration fault, but the explicit `UNREGISTERED_ON_API_CONSOLE` reason now offers registration help rather than only suggesting retries. The account picker alone does not establish successful authorization.

## Reading controls

TXT, EPUB and PDF use a compact reader bar. EPUB opens with the bar and system bars hidden, with no floating button covering the book. Tap the center area to show or hide the controls; edge taps retain Readium page navigation. Accessibility actions also show or hide the bar. TXT and PDF retain their small **Show controls** button.

EPUB's **Aa** panel provides serif, sans and monospace fonts, text size, System/Light/Sepia/Dark/Custom colors, scrolling, one page and two pages. Changes are saved on this device and apply to the open book. Two pages use screens at least 600 dp wide, with one page on compact screens; fixed-layout EPUBs retain their original typography. Font and color preferences are shared with TXT, while EPUB's page layout is saved separately. TXT also groups its appearance options under **Aa**. Reading gestures and native text selection remain available while the bar is hidden. See [current reader evidence](../../docs/engineering/evidence/UNIFIED-KOTLIN-01.md) for checks and limits.

Dropbox and pCloud app IDs are configured by the user in Settings. WebDAV, SFTP, and folder sync use user-provided connection details. Credentials are encrypted with an Android Keystore key, are excluded from device backup, and are never included in the shared sync index. Live provider checks require the corresponding provider app registrations and user credentials.

The app implements the current CloudReader schema-v1 sync format. It uses Foundation reference-date seconds, uppercase UUIDs in object names, and lowercase SHA-256 hashes. Local precise reader positions stay on device; the portable progress fraction is synchronized.

The Android 12 instrumentation test covers document-stream import, duplicate display names, CJK TXT bytes, preservation of the source stream, and unsupported-file rejection. The library, TXT reader, and process-restored reading progress were manually checked offline on Android 12; launch and process recreation were checked on Android 16. The current reader/credentials update also has isolated reader UI tests and Android 17 emulator smoke checks; see its evidence file for exact dimensions and results. Physical folding/hinge behavior, broader accessibility, cross-platform sync, and live provider/OAuth checks still need validation.


## Shared Android / Windows / Linux application (1.2.0 work)

The app now compiles its responsive library, navigation, assistant and publication
controls from `Packages/CloudReaderUI`; portable models, remote AI transport and
safe EPUB/FB2/CBZ preparation live in `Packages/CloudReaderKotlin`. The Room v1
database, Android application ID, secure credential keys and imported originals
are retained. The iOS-enabled reader set is the target: EPUB/PDF/TXT plus the new
FB2/CBZ host. MOBI/AZW3/CBR stay storage-only, matching the current iOS gates.

Android picker, external Open and Share use one durable import path and open the
first successful import. Readium stays native; it reopens its publication and
locator after recreation and exposes Ask AI in the text-selection menu. New
FB2/CBZ readers share their preparation/controls with desktop. Physical-device
recreation, gestures and accessibility still require acceptance beyond JVM tests.

Run `bash scripts/build-app.sh android` for isolated build output and a preview
APK. `release.properties` controls all three app versions. The **Android, Windows
and Linux** workflow collects APK/MSI/DEB from one revision only after every job
passes. APKs from this workflow are debug-signed previews; configure stable
release signing before distributing install-preserving production updates.
