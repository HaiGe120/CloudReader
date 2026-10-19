# CloudReader for Android

Native Kotlin and Jetpack Compose application. Android 12 (API 31) or newer.

## Build

Install JDK 17 and Android SDK Platform 37, Build Tools 37, Platform Tools, and ARM64 Google APIs system images for Android 12 (API 31) and the current platform. Android Studio Device Manager or the Android CLI can create the emulators. The Gradle wrapper is the supported build entry point:

```sh
./gradlew assembleDebug
./gradlew testDebugUnitTest
./gradlew lintDebug
./gradlew connectedDebugAndroidTest
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

To register Google Drive, run `./gradlew signingReport` and copy the `SHA1` for the `debug` variant. This checkout's current debug SHA-1 is `E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`; it belongs to this Mac's debug keystore and changes if that keystore is replaced. Add Android package `io.github.haige120.cloudreader` and the signing certificate to the Android OAuth client in the same Google Cloud project as the Apple clients. Google Play services is required for Drive; foreground sync requests renewed authorization through Play services. Other app features remain available without it.

Dropbox and pCloud app IDs are configured by the user in Settings. WebDAV, SFTP, and folder sync use user-provided connection details. Credentials are encrypted with an Android Keystore key, are excluded from device backup, and are never included in the shared sync index. Live provider checks require the corresponding provider app registrations and user credentials.

The app implements the current CloudReader schema-v1 sync format. It uses Foundation reference-date seconds, uppercase UUIDs in object names, and lowercase SHA-256 hashes. Local precise reader positions stay on device; the portable progress fraction is synchronized.

The Android 12 instrumentation test covers document-stream import, duplicate display names, CJK TXT bytes, preservation of the source stream, and unsupported-file rejection. The library, TXT reader, and process-restored reading progress were manually checked offline on Android 12; launch and process recreation were checked on Android 16. Tablet/foldable, accessibility, full reader-format, cross-platform sync, and live provider/OAuth checks still need broader validation.
