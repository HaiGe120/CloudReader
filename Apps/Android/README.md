# CloudReader for Android

Native Kotlin and Jetpack Compose application. Android 12 (API 31) or newer.

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

Settings accepts your own **Web application OAuth client ID and client secret**. Save them, then tap Google Drive **Connect**. The secret and refresh token are encrypted with Android Keystore and excluded from backup and the shared sync index. A blank secret keeps the saved secret only for the same client ID. Changing either credential clears Google's previous grant and requires reconnecting; clearing the client ID returns to native Google authorization.

The Web client must belong to the Google Cloud project that owns this APK's **Android OAuth registration**. In that project, enable the Drive API and configure the consent audience/test users. Settings → **Android registration details** displays the installed package and signing SHA-1. Android clients themselves do not have a client secret. Google permits a package/SHA-1 pair in only one project, so Web credentials from an unrelated project cannot bypass that registration requirement. A separately signed build needs its own matching registration. See [Google's registration restriction](https://support.google.com/firebase/answer/6401008?hl=en).

To inspect a locally built APK's certificate, run `./gradlew signingReport` and use the `SHA1` for that variant. This preview's debug SHA-1 is `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`; replacing the signing keystore changes it. The package is `io.github.haige120.cloudreader`.

The configured flow uses native Google account/consent UI, then exchanges its server authorization code with the user-supplied Web credentials and renews with an encrypted refresh token. Google's documentation describes that exchange as a backend operation; this app performs it locally using the user's credentials. No developer client secret is bundled. Without custom credentials, the existing native Play services authorization remains available. Successful authorization with a real Google account has **not** been verified in this repair. See [Google authorization](https://developer.android.com/identity/authorization) and [native code exchange parameters](https://developer.android.com/identity/legacy/gsi/offline-access).

Connection status remains visible below the Google row. Returned intents are parsed even when Android reports a non-OK result; errors include the authorization stage and sanitized provider detail. Error 8 is an internal Google error, not proof of a particular registration fault. The native account picker alone does not establish successful authorization. See [initial repair evidence](../../docs/engineering/evidence/ANDROID-AUTH-01.md) and [reader/credentials update evidence](../../docs/engineering/evidence/ANDROID-READER-02.md).

## Reading controls

TXT, EPUB and PDF use a compact reader bar. EPUB opens with the bar and system bars hidden, with no floating button covering the book. Tap the center area to show or hide the controls; edge taps retain Readium page navigation. Accessibility actions also show or hide the bar. TXT and PDF retain their small **Show controls** button.

EPUB's **Aa** panel provides serif, sans and monospace fonts, text size, System/Light/Sepia/Dark/Custom colors, scrolling, one page and two pages. Changes are saved on this device and apply to the open book. Two pages use screens at least 600 dp wide, with one page on compact screens; fixed-layout EPUBs retain their original typography. Font and color preferences are shared with TXT, while EPUB's page layout is saved separately. TXT also groups its appearance options under **Aa**. Reading gestures and native text selection remain available while the bar is hidden. See [EPUB appearance evidence](../../docs/engineering/evidence/ANDROID-EPUB-03.md) for checks and limits.

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
