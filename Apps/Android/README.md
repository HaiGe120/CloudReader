# CloudReader for Android

Native Kotlin and Jetpack Compose application. Android 12 (API 31) or newer.

## 1.2.1 Google connection preview

Download the [1.2.1 prerelease](https://github.com/HaiGe120/CloudReader/releases/tag/v1.2.1-google-connect-preview):
`CloudReader-1.2.1-android-debug.apk` (version 1.2.1, code 5) or the all-platform
preview ZIP. Compiled revision: `48d8b5e154bc5b101bb85051d869836e02039069`; coordinated run `41315984334`.
See [release notes and exact hashes](../../docs/releases/1.2.1-google-connect-preview.md).
Keep the notices companion/source references with redistributions.

The release APK is built **locally from the same frozen source and version** as
the coordinated packages, with the retained older preview key. Its certificate
SHA-1 is `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`, already
registered with Google. **No signing private key is uploaded to GitHub or CI.**
The public 1.2.0 APK's certificate is
`4F:2D:16:4E:E4:43:9D:5E:6A:1F:76:F2:AF:38:EC:6A:A9:77:84:C7`; its private
signing key is unavailable. **1.2.1 is not an in-place update over public 1.2.0.**
Do not uninstall CloudReader or clear app data to bypass the mismatch. The key
may match some 1.0.x previews, but installed update/data retention is untested.

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

The 1.2.1 preview hides custom credentials under **Advanced Google settings (optional)** and pairs destination-card colors with the light/dark theme shared with Windows/Linux. Existing custom grants are preserved until the user explicitly chooses **Use standard Google connection**; that choice retains advanced credentials, invalidates only the old Google grant and requires fresh consent. Books and other provider connections are retained. The public 1.2.0 preview has the older credential-heavy layout. See the [1.2.1 release notes](../../docs/releases/1.2.1-google-connect-preview.md) for publication status and the [prior repair evidence](../../docs/engineering/evidence/GOOGLE-CONNECT-UI-01.md) for its earlier source/tests.

Both approved new Google clients were created and verified in the existing project; the older Android registration remains available for the retained 1.2.1 key. Drive API is enabled and the existing audience is **External / In production**. These registration checks do not establish a successful account connection. The owner has not retried personal-account sign-in; live consent, refresh and Drive sync remain **not verified**.

The final 1.2.1 source passed 127 JVM tests, lint and APK assembly in both CI
and the local retained-key build. Its actual published APK passed six disposable
API 31 emulator UI tests: real light/dark standard/Advanced settings and cards
at 320/360dp with 1.5× font. Screenshots were inspected; contrast tests cover
17 text pairs. This does not verify live OAuth, physical devices or installed
updates. See [release evidence](../../docs/engineering/evidence/RELEASE-1.2.1.md).

For optional developer/self-build configuration only, a custom **Web application** client and its secret must belong to the same project as the APK's **Android OAuth registration**. Android clients themselves do not have a secret. Enable the Drive API and configure consent/test users. A Web ID and secret alone cannot replace package/certificate registration. The secret and refresh grant remain encrypted with Android Keystore and excluded from backup/sync manifests. A blank secret retains the saved value only for the same client ID; changed credentials require reconnecting. Custom server-code exchange is an advanced compatibility path, not required for normal native authorization.

To inspect a locally built APK's certificate, run `./gradlew signingReport` and
use the `SHA1` for that variant. A CI runner's debug key can differ from a local
build or earlier preview. Use **Android registration details** in the installed
app or inspect the actual downloaded APK; do not reuse a historical certificate
fingerprint. The package remains `io.github.haige120.cloudreader`.

No developer Web client secret is bundled in Android. Successful authorization with a real Google account has **not** been verified for this release. See [Google authorization](https://developer.android.com/identity/authorization).

Connection status remains visible below the Google row, with optional expandable diagnostics. Returned intents are parsed even when Android reports a non-OK result; errors retain sanitized provider details. Generic error 8 alone does not establish a registration fault, but the explicit `UNREGISTERED_ON_API_CONSOLE` reason now offers registration help rather than only suggesting retries. The account picker alone does not establish successful authorization.

## Reading controls

TXT, EPUB and PDF use a compact reader bar. EPUB opens with the bar and system bars hidden, with no floating button covering the book. Tap the center area to show or hide the controls; edge taps retain Readium page navigation. Accessibility actions also show or hide the bar. TXT and PDF retain their small **Show controls** button.

EPUB's **Aa** panel provides serif, sans and monospace fonts, text size, System/Light/Sepia/Dark/Custom colors, scrolling, one page and two pages. Changes are saved on this device and apply to the open book. Two pages use screens at least 600 dp wide, with one page on compact screens; fixed-layout EPUBs retain their original typography. Font and color preferences are shared with TXT, while EPUB's page layout is saved separately. TXT also groups its appearance options under **Aa**. Reading gestures and native text selection remain available while the bar is hidden. See [current reader evidence](../../docs/engineering/evidence/UNIFIED-KOTLIN-01.md) for checks and limits.

Dropbox and pCloud app IDs are configured by the user in Settings. WebDAV, SFTP, and folder sync use user-provided connection details. Credentials are encrypted with an Android Keystore key, are excluded from device backup, and are never included in the shared sync index. Live provider checks require the corresponding provider app registrations and user credentials.

The app implements the current CloudReader schema-v1 sync format. It uses Foundation reference-date seconds, uppercase UUIDs in object names, and lowercase SHA-256 hashes. Local precise reader positions stay on device; the portable progress fraction is synchronized.

The Android 12 instrumentation test covers document-stream import, duplicate display names, CJK TXT bytes, preservation of the source stream, and unsupported-file rejection. The library, TXT reader, and process-restored reading progress were manually checked offline on Android 12; launch and process recreation were checked on Android 16. The current reader/credentials update also has isolated reader UI tests and Android 17 emulator smoke checks; see its evidence file for exact dimensions and results. Physical folding/hinge behavior, broader accessibility, cross-platform sync, and live provider/OAuth checks still need validation.


## Shared Android / Windows / Linux application

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
For 1.2.1, the public APK is the separately recorded local build with the retained
key described above, not the workflow's independently debug-signed APK. Its frozen source/version/signature/digest were verified, and that same APK is
included in the all-platform bundle. Native Apple apps, schema v1, dependencies, SDK minimums,
application IDs and credential-storage identifiers are unchanged by this release.
