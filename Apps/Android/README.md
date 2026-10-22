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

To register Google Drive, run `./gradlew signingReport` and copy the `SHA1` for the `debug` variant. This checkout's current debug SHA-1 is `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`; it belongs to this Mac's debug keystore and changes if that keystore is replaced. Add Android package `io.github.haige120.cloudreader` and the signing certificate to the Android OAuth client in the same Google Cloud project as the Apple clients. Google Play services is required for Drive; foreground sync requests renewed authorization through Play services. Other app features remain available without it.

Google connection now keeps a visible pending/result status below its Settings row. Returned intents are parsed even when Android reports a non-OK activity result, so provider errors are not silently discarded. Configuration errors show the installed package/signing fingerprint; use those values to check the Android OAuth client, enabled Drive API, and consent-screen test users. The native account picker alone does not prove the app is registered correctly. See [Google's authorization setup and result handling](https://developer.android.com/identity/authorization) and [the 2026-10-22 repair evidence](../../docs/engineering/evidence/ANDROID-AUTH-01.md) for validation limits and remaining audit findings.

Dropbox and pCloud app IDs are configured by the user in Settings. WebDAV, SFTP, and folder sync use user-provided connection details. Credentials are encrypted with an Android Keystore key, are excluded from device backup, and are never included in the shared sync index. Live provider checks require the corresponding provider app registrations and user credentials.

The app implements the current CloudReader schema-v1 sync format. It uses Foundation reference-date seconds, uppercase UUIDs in object names, and lowercase SHA-256 hashes. Local precise reader positions stay on device; the portable progress fraction is synchronized.

The Android 12 instrumentation test covers document-stream import, duplicate display names, CJK TXT bytes, preservation of the source stream, and unsupported-file rejection. The library, TXT reader, and process-restored reading progress were manually checked offline on Android 12; launch and process recreation were checked on Android 16. Tablet/foldable, accessibility, full reader-format, cross-platform sync, and live provider/OAuth checks still need broader validation.
