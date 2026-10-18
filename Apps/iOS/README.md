# CloudReader for iOS

Native SwiftUI app targeting iOS 26.0. The project uses iOS 26 Liquid Glass APIs and Apple frameworks for document import, PDF, and EPUB preview.

From this folder, run `xcodegen generate --spec CloudReader.xcodegen.yml`, open `CloudReader.xcodeproj`, select the `CloudReader` scheme and an iPhone or iPad simulator, and press **Run**. Local simulator tests run with:

```sh
xcodebuild -project CloudReader.xcodeproj \
  -scheme CloudReader \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  test
```

Replace `iPhone Duo` with the name of another installed simulator if needed.

See [the iOS-first guide](../../docs/IOS_FIRST.md) for supported features and current limits.
