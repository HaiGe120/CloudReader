# CloudReader for macOS

Native SwiftUI desktop app targeting macOS 15. It shares the iOS book model, library manager, sync coordinator, AI service, and Siri/Shortcuts App Intent from `Apps/Shared`, while keeping Mac-native windows, settings, and readers.

The app supports importing and searching books, favorites, TXT and PDF readers, EPUB through Quick Look, and automatic foreground sync through Google Drive, Dropbox, pCloud, WebDAV, SFTP, or a selected Finder folder. TXT and PDF support scroll, single-page, and facing-page layouts; facing pages switch to one page when the reader window is too narrow. Select one or more matching destinations on each device; CloudReader merges their contents and updates each selected destination. Google Drive requires a Google Cloud OAuth client of type **Desktop app** in Settings. Dropbox and pCloud app identifiers also stay in Settings. AI supports the existing remote API providers and Apple's on-device Foundation Model when running macOS 26 or later on an eligible device with Apple Intelligence available. The app exposes an `Ask CloudReader` action; on Mac, add it to a custom shortcut in Shortcuts.

## Run

Requirements: Xcode 26 or later and XcodeGen.

```sh
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

Select the **CloudReader** scheme and **My Mac**, then Run. To build from the repository root:

```sh
xcodebuild -project Apps/macOS/CloudReader.xcodeproj \
  -scheme CloudReader \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/CloudReaderMacDerivedData CODE_SIGNING_ALLOWED=NO build
```

The Mac sync coordinator uses the same v1 manifest and SHA-256 book objects as iOS. Provider credentials and selected destinations are configured separately on each device. Auto-sync runs when the app becomes active and after local library changes; background transfer and conflict-choice UI are not included yet.
