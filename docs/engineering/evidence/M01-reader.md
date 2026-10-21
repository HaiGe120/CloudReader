# M01.reader — Mac reader parity

Status: complete at local Mac runtime/UI gates, 2026-10-21. This bounded sub-batch follows the user's request to apply the iOS reader repair and new formats to macOS; the wider M01 backlog remains separate.

## Ownership and boundary

- Coordinator: shared contracts/preparation, XcodeGen specifications and generated projects, dependency locks, isolated test launch, integration and regression repair.
- Mac shell/native worker: `MacBookReaderView.swift`, `MacNativeReaderTests.swift`. Integration separates the final shell, `MacNativeBookReaders.swift` and `MacReaderAppearanceView.swift` for future bounded work.
- Mac reflow worker: `MacEPUBBookReader.swift`, `MacReflowReaderTests.swift`.
- Mac comic worker: `MacComicBookReader.swift`, `MacComicReaderTests.swift`.

The dirty/untracked starting tree was copied to `<local path>` before changes. No unrelated working-tree files were reset or removed.

## Implementation

The platform shells share `ReaderContracts.swift`, `ReaderChromeControls.swift`, FB2, Kindle, CBZ and CBR publication preparation under `Apps/Shared`. UIKit/AppKit renderer hosts stay on their own platforms. The Mac route uses the native reflow renderer for EPUB/FB2/MOBI/AZW3, PDFKit for PDF, native TXT and image adapters for TXT/CBZ/CBR. Imported bytes, v1 progress, favorite semantics and existing preference keys stay intact. The iOS MOBI/CBR availability gates remain unchanged. Mac tests observe actual adapter-to-shell presentation through a native SwiftUI preference; this is transient UI state and does not enter the portable model.

MOBI/AZW3 support is limited to DRM-free reflowable Kindle formats; KFX, DRM, print replica, dictionaries and fixed-layout variants remain unsupported. Comics preserve original artwork/color, use left-to-right order and reuse existing bounded archive preparation and image downsampling.

## Reproduction and isolation

```sh
scripts/check-macos-reader.sh unit
scripts/check-macos-reader.sh ui
```

The script regenerates the canonical Mac project and uses a separate `io.github.haige120.cloudreader.macos.readerChecks` application identity. Unit tests use temporary storage and isolated defaults. UI tests launch the real library/navigation/reader flow with `CLOUDREADER_UI_TEST_MODE=1`, a unique session library/defaults suite and no personal sync. Only the test build omits sandboxing to read test fixtures from the checkout; normal app configuration retains its sandbox and original bundle identifier.

## Verification

- Shared-source extraction: iPhone Duo simulator unit suite, **132 passed, 0 failures, 0 runtime warnings** (`Test-CloudReader-2026.10.21_15-34-45-+0800.xcresult`). Includes the additional absolute ZIP-directory rejection regression.
- Mac runtime suite: **62 passed, 0 failures**, on the M1 Pro running macOS 27.0.1 (`Test-CloudReader-2026.10.21_16-36-50-+0800.xcresult`). Covers all eight formats through the composed shell, actual native wheel event dispatch and exactly one spread turn, widths 699/700, publisher-script isolation, nested bold, font-change passage anchoring, footnotes/backlinks, comic gesture coalescing and zoom state, and PDF page/destination/selection/zoom across resize and chrome changes.
- Mac end-to-end UI suite: **4 passed, 0 failures, 0 skipped**, no recorded runtime warnings (`Test-CloudReader-2026.10.21_16-38-39-+0800.xcresult`). Real application checks cover wide spread and narrow single-page EPUB gestures, visible/hidden/restored chrome, TXT click/shortcut restoration, all new format routes, comic swipes and odd final spread, and PDF page retention. Matching screenshots are retained in the result bundle and exported to `<local path>`.
- Integration repaired the Mac Quick Look route, duplicate controls, unsafe single-click handling, spread stride, stale note navigation, source-anchor loss on reflow, PDF state mutation during representable updates, and test-only fixture copying that stalled inside `clonefileat`. Early failed UI/fixture runs are superseded by the passing final runs above. The native AppKit PDF layout path still emits a console layout notice on this OS build; state-preservation assertions pass and Xcode records no runtime issue.
- Physical iPhone testing remains deferred at the user's request and is independent of this Mac batch.
- Live personal-library upgrade, live AI/provider requests, multi-window interactions and deployment to older macOS releases are outside this reader batch. The production minimum remains macOS 15; no personal library or sync destination was used by these tests.

## Deliverable

- `Build/macOS/CloudReader-macOS-reader-parity.zip` contains the ARM64 Mac app, signed locally with the original `io.github.haige120.cloudreader.macos` identifier and app sandbox enabled. A sandboxed EPUB launch was verified through an isolated test library; its page status reported `Pages 1–2 of 7`.
- Archive SHA-256: `413b6e77f6c511d7179f71ccfdacde053d504ccf2ae1a4d1db2b7fe90101ea75`. The ZIP was extracted into a clean temporary folder and passed `codesign --verify --deep --strict`.
- The loose copy is `Build/macOS/CloudReader.app`; the previous build is preserved as `Build/macOS/CloudReader-before-reader-parity-20261021-1645.app`. The Documents File Provider automatically attaches Finder metadata to loose app bundles here, so use the ZIP for distribution. No source-file metadata or personal library data was altered to work around that build-folder issue.
- The sandboxed build used the clean `<local path>` output with the normal project settings: `xcodebuild -project Apps/macOS/CloudReader.xcodeproj -scheme CloudReader -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath <local path> -disableAutomaticPackageResolution CLOUDREADER_APP_BUNDLE_IDENTIFIER=io.github.haige120.cloudreader.macos CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES build`. This final build changes the output identity from the isolated test identity back to the normal app identity; the test script restores its own isolated identity on the next run.
