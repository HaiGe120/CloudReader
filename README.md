# CloudReader

CloudReader is a private, offline-first book library. The native SwiftUI iOS app targets iOS 26 and later, the native SwiftUI macOS app targets macOS 15 and later, and the native Kotlin/Compose Android app targets Android 12 and later. The Apple targets compile the shared model, cloud sync, AI service, and Ask CloudReader App Intent from `Apps/Shared`; Android implements the same portable schema with a native interface. There is no active web app.

See the [CloudReader product and platform specification](docs/PROJECT_SPEC.md) for the cross-platform data contract, sync plan, AI endpoint behavior, privacy rules, and feature status. The included [demo book](docs/CloudReader_Field_Guide.txt) is original sample text dedicated under CC0 1.0.

For the proposed code structure and platform-by-platform coding tasks, start with the [engineering architecture and implementation plan](docs/engineering/README.md). It includes the current-state audit, migration order, bounded agent assignments, and verification/repair rules; planned modules and features are labeled separately from current implementation.

## iOS status

The native build imports supported book files from Files or **Open in CloudReader**, keeps the source files untouched, and opens the first imported book directly. CloudReader also appears in other apps' share sheets: sharing saves a copy, and opening CloudReader imports and opens it automatically. The library persists across launches and saves local PDF, EPUB, and TXT reading positions. DRM-free EPUBs open in an in-app chapter reader with cached preparation, chapter navigation, adjustable typography/themes, and selected-passage AI. On wide screens, TXT and PDF readers offer facing pages; TXT also supports adjustable fonts, type size, and system/light/sepia/dark/custom themes. Selecting TXT text adds an Ask AI action, and PDF selections expose a contextual Ask AI button. FB2 uses the reflow reader and CBZ uses a native comic reader. MOBI/AZW3 and CBR preparation is implemented, while their iOS reader availability remains gated pending device verification. The library layout adapts to compact iPhone and wide iPhone Duo/iPad widths.

The iOS app can sync books and reading state to selected Google Drive, Dropbox, pCloud, WebDAV, or SFTP destinations. It can also sync to a folder chosen in Files, including iCloud Drive, SMB shares, and storage providers that expose folders in Files. MEGA and PikPak do not yet have direct iOS adapters; their Files locations can be used when exposed by the installed apps. See [iOS setup and sync](docs/IOS_FIRST.md) for provider configuration. Auto-sync runs after local changes and when the app becomes active. For two devices changing the same book offline, the latest saved state currently wins.

The library seeds an original CC0 sample book, **The Open Shelf**, so a new installation opens directly into a working reading experience. Books, reading progress, bookmark flags, and saved AI conversation history are kept locally and sync to the selected cloud destinations. Conversation history includes the saved book context; Apple API keys and provider credentials remain in Keychain, while Android credentials use Android Keystore-backed storage. The optional AI assistant supports OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, compatible custom HTTPS endpoints, and Apple's on-device Foundation Model on eligible Apple Intelligence devices. The Ask CloudReader App Intent uses the selected AI provider; iOS supplies Siri phrases, while Mac users can add the intent to a custom Shortcuts action. The full cross-platform feature and data contract is in [docs/PROJECT_SPEC.md](docs/PROJECT_SPEC.md).

The interface uses SwiftUI and iOS 26's native Liquid Glass APIs for interactive controls, with the system tab bar providing its native glass presentation.

## Apple preview download

The [CloudReader 1.1.0 Apple Reader Preview](https://github.com/HaiGe120/CloudReader/releases/tag/v1.1.0-apple-reader-preview) includes current iOS and macOS builds. The iOS IPA is signed for App Store Connect distribution and must be uploaded there for TestFlight or App Store delivery; it cannot be installed directly from GitHub. The macOS ZIP contains an ad hoc signed, non-notarized universal app for macOS 15 or later, so Gatekeeper may require opening it from Finder. Physical iPhone Air reader verification is still pending. Android remains available in the earlier [1.0 multi-platform preview](https://github.com/HaiGe120/CloudReader/releases/tag/v1.0-multiplatform-preview).

## macOS status

The Mac app provides a desktop library with book import, search, favorites, and local persistence. EPUB, FB2 and DRM-free reflowable MOBI/AZW3 books use the built-in chapter reader with shared typography, saved position, selection and native page turns. TXT uses matching scroll/page/spread appearance, CBZ/CBR use native comic readers with zoom, and PDFKit preserves page, destination, selection and zoom. Reader controls hide/restore with a clean content click or ⌘⇧R; spreads use a 700-point width threshold. PDF single-page mode remains continuous. The [Mac reader batch](docs/engineering/evidence/M01-reader.md) passes 62 runtime and 4 end-to-end UI checks. Google Drive, Dropbox, and pCloud app IDs remain editable in Settings. Google Drive uses a Desktop OAuth client and the system browser; Dropbox and pCloud use their configured app identifiers. The Mac app shares the iOS data model and sync wire format. Sync can run on launch, when the app returns to the foreground, and after local library changes. macOS 26+ can use Apple Foundation Models when available; older supported macOS versions can use a configured remote AI endpoint.

## Android status

The Android app builds as an installable debug APK. It provides an offline Room-backed library, TXT/PDF/EPUB readers, reading progress, favorites, saved AI conversations, multi-destination schema-v1 sync, and remote AI. TXT includes selectable text, adjustable typography and themes, and facing pages on wide windows; PDF and EPUB use AndroidX PDF and Readium. MOBI, AZW3, FB2, CBZ, and CBR can be stored while their readers are still pending. See [Android setup](Apps/Android/README.md) for build, installation, and Google Drive registration details.

## Run on iPhone or iPad Simulator

Requirements: Xcode 26 or later, the iOS 26 SDK, and XcodeGen.

```sh
cd Apps/iOS
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

In Xcode, select the `CloudReader` scheme and an iOS 26 or later iPhone or iPad simulator, then Run. The project has a deployment target of iOS 26.0. For command-line simulator builds:

```sh
xcodebuild -project Apps/iOS/CloudReader.xcodeproj \
  -scheme CloudReader \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/CloudReaderDerivedData build
```

On a physical device, choose your development team under **Signing & Capabilities**. See the [iOS-first guide](docs/IOS_FIRST.md) for details.

## Run on Mac

Requirements: Xcode 26 or later, the macOS 15 SDK, and XcodeGen.

```sh
cd Apps/macOS
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

Select the **CloudReader** scheme and run it on **My Mac**. For a command-line build:

```sh
xcodebuild -project Apps/macOS/CloudReader.xcodeproj \
  -scheme CloudReader \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CloudReaderMacDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Build products go to `/tmp/CloudReaderMacDerivedData`. Open the app from that build folder, or use **Run** in Xcode to launch it with the debugger attached.

## Repository layout

```text
Apps/
  iOS/       Native SwiftUI app and Xcode project
  macOS/     Native SwiftUI app and Xcode project
  Shared/    Book model, library, provider sync, AI service, and App Intent compiled into Apple targets
  Android/   Native Kotlin/Compose Android app; see Apps/Android/README.md
  Linux/     Reserved for a later platform phase
  Windows/   Reserved for a later platform phase
docs/
```

## License

CloudReader is distributed under the MIT License. See [third-party notices](THIRD_PARTY_NOTICES.md) for the SFTP transport dependency.
