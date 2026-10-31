# CloudReader

CloudReader is an offline-first book library and reader for iPhone, iPad, Mac, and Android. Import books into CloudReader's local library while keeping the original files untouched. The library works without an internet connection, and CloudReader does not require an account or run a hosted sync service.

Sync directly with storage destinations you choose. Your books, reading progress, favorites, deletions, and saved AI conversations can move between devices; provider credentials stay on each device.

## Features

- Read DRM-free books with native apps for each platform.
- Import from the Files app, Android document picker, or supported share flows.
- Choose multiple sync destinations, including Google Drive, Dropbox, pCloud, WebDAV, SFTP, and platform file providers. Availability varies by platform.
- Ask questions with a compatible remote AI service, or use Apple's on-device model on supported Apple devices. Book text is included only when you choose to share it with a question.
- Keep library data and credentials separate: provider tokens and AI keys are stored in the operating system's secure credential store and are not included in sync data.

## Platform support

| Platform | Minimum version | Reading support |
| --- | --- | --- |
| iOS and iPadOS | iOS 26 | EPUB, PDF, TXT, FB2, and CBZ readers. Additional formats can be imported; see the [iOS guide](docs/IOS_FIRST.md) for current reader availability. |
| macOS | macOS 15 | EPUB, FB2, MOBI/AZW3, TXT, PDF, and CBZ/CBR readers. |
| Android | Android 12 (API 31) | EPUB, PDF, TXT, FB2, and CBZ readers; other formats remain storage-only. |
| Windows | Windows 10/11 x64 | Shared Kotlin/Compose client; TXT, PDF, EPUB, FB2 and CBZ reader hosts. |
| Linux | Debian 12 x64 baseline | Same shared desktop client; other distributions can build from source. |

The iOS and macOS apps share their Swift data model and sync implementation. Android is a native Kotlin and Jetpack Compose app that follows the same portable schema. Windows and Linux share a Kotlin/JVM desktop client while keeping OS integrations separate; there is no web app.

## Get a preview

See [GitHub Releases](https://github.com/HaiGe120/CloudReader/releases) for available builds and platform-specific installation notes.

## Build from source

### iOS and iPadOS

Requirements: Xcode 26 or later, the iOS 26 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd Apps/iOS
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

Select the **CloudReader** scheme and an iOS 26 or later simulator, then run. For a physical device, configure your development team in Xcode. See the [iOS setup guide](docs/IOS_FIRST.md) for signing, imports, provider setup, and AI configuration.

### macOS

Requirements: Xcode 26 or later, the macOS 15 SDK, and XcodeGen.

```sh
cd Apps/macOS
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

Select the **CloudReader** scheme and run it on **My Mac**.

### Android

Requirements: JDK 17 and the Android SDK. From the repository root:

```sh
cd Apps/Android
./gradlew assembleDebug
```

The debug APK is created at `Apps/Android/app/build/outputs/apk/debug/app-debug.apk`. See the [Android guide](Apps/Android/README.md) for checks, emulator setup, and Google Drive registration.

### Windows and Linux desktop prototype

Requirements: JDK 17 or later. From the repository root:

```sh
./scripts/check-desktop.sh
```

Set `CLOUDREADER_PACKAGE=1` to build the current platform distribution. The shared Android/desktop application uses the current iOS feature set as its
reference. Use the **Android, Windows and Linux** workflow for coordinated
same-version APK/MSI/DEB output. See [desktop setup and verification limits](Apps/Desktop/README.md)
and [the convergence task](docs/engineering/UNIFIED_KOTLIN.md).

## Project documentation

- [Product and platform specification](docs/PROJECT_SPEC.md)
- [Portable sync contract](Contracts/v1/README.md)
- [iOS setup](docs/IOS_FIRST.md)
- [Android setup](Apps/Android/README.md)
- [Engineering architecture and implementation plan](docs/engineering/README.md)

## Repository layout

```text
Apps/
  iOS/       Native SwiftUI app
  macOS/     Native SwiftUI app
  Shared/    Shared Apple models, sync, AI, and App Intent
  Android/   Native Kotlin and Compose app
  Desktop/   Shared Kotlin/JVM desktop app for Windows and Linux
  Linux/     Linux packaging and native integration
  Windows/   Windows packaging and native integration
docs/        Product and platform documentation
Packages/    Shared Swift package and contract tests
```

The included sample book, **The Open Shelf**, is original text released under CC0 1.0.

## License

CloudReader is distributed under the [MIT License](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses.
