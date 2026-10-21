# CloudReader for macOS

Native SwiftUI desktop app targeting macOS 15. It shares the iOS book model, library manager, sync coordinator, AI service, and Siri/Shortcuts App Intent from `Apps/Shared`, while keeping Mac-native windows, settings, and readers.

The app supports importing and searching books, favorites, native EPUB/TXT/PDF/FB2/CBZ/CBR readers, and DRM-free reflowable MOBI/AZW3 books. EPUB, FB2 and Kindle books share the app's typography, margins, themes, chapter controls and paged layouts. Two-page layouts use the actual reader width and fall back to one page below 700 points. Comics preserve their artwork and support scrolling, pages, spreads and zoom. A clean content click hides/restores the reader controls; ⌘⇧R and the accessible restore button also restore them. Selection, links and zoom retain their native interactions. PDF single-page mode remains continuous; its page, selection and zoom are preserved across reader layout changes.

Automatic foreground sync supports Google Drive, Dropbox, pCloud, WebDAV, SFTP, or a selected Finder folder. Select one or more matching destinations on each device; CloudReader merges their contents and updates each selected destination. Google Drive requires a Google Cloud OAuth client of type **Desktop app** in Settings. Dropbox and pCloud app identifiers also stay in Settings. AI supports the existing remote API providers and Apple's on-device Foundation Model when running macOS 26 or later on an eligible device with Apple Intelligence available. The app exposes an `Ask CloudReader` action; on Mac, add it to a custom shortcut in Shortcuts.

Encrypted books/archives, KFX, Kindle print replica, dictionaries and fixed-layout Kindle variants remain unsupported. Reader preparation shares the Apple cache/archive limits and preserves imported original files. Platform reader availability is separate from the portable book-format model.

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

Reader checks from the repository root: `scripts/check-macos-reader.sh unit` or `scripts/check-macos-reader.sh ui`. The latter requires macOS UI-testing authorization. Both use an isolated app identity and temporary libraries/preferences. See [reader verification](../../docs/engineering/evidence/M01-reader.md) for measured results and remaining limits.
