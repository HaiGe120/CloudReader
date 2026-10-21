# CloudReader for iOS

Native SwiftUI app targeting iOS 26.0, with iOS 26 Liquid Glass, PDFKit, a native TXT reader, and an in-app DRM-free EPUB reader. EPUB preparation runs off the main thread and is cached for later opens; chapter navigation, typography/themes, reading progress, and selected-passage AI are supported.

EPUB, FB2 and TXT share app-controlled reading appearance and a common hideable controls shell. CBZ uses the native comic adapter. MOBI/AZW3 and CBR preparation is implemented and covered by simulator fixtures, but these formats remain unavailable in the reader until the physical/wide-reader and format acceptance gates pass. See [the reader implementation cards](../../docs/engineering/IMPLEMENTATION_PLAN.md#ios-reader-repair-and-format-expansion) and [verification evidence](../../docs/engineering/evidence/IOS-R04.md) for current limits.

Import from Files or **Open in CloudReader** to open a book directly. The **CloudReader** share-sheet extension saves a copy from other apps; open CloudReader afterward to import and read it automatically. The extension does not force the host app to switch to CloudReader. The app and extension must be signed for the same team with the `group.io.github.haige120.cloudreader` App Group enabled.

From this folder, run `xcodegen generate --spec CloudReader.xcodegen.yml`, open `CloudReader.xcodeproj`, select the `CloudReader` scheme and an iPhone or iPad simulator, and press **Run**. Local simulator tests run with:

```sh
xcodebuild -project CloudReader.xcodeproj \
  -scheme CloudReader \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  test
```

Replace `iPhone Duo` with the name of another installed simulator if needed.

See [the iOS-first guide](../../docs/IOS_FIRST.md) for supported features and current limits.
