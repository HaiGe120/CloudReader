# M01.reader — EPUB navigation flicker repair

Status: implemented and verified locally, 2026-10-24. Scope is the user's report of flashing during macOS EPUB page turns and chapter jumps.

## Owned paths and behavior

- `Apps/macOS/CloudReader/MacEPUBBookReader.swift`: position-only navigation no longer reapplies the appearance stylesheet or recalculates page columns. Publisher smooth scrolling cannot animate a page restoration. Chrome visibility alone is excluded from layout identity.
- New chapter documents have a document-start root-opacity gate while their reader appearance and requested location settle. The gate preserves geometry and works for HTML with explicitly visible descendants and SVG chapters. A native snapshot holds the outgoing page until the new page has been composited; a short chapter load no longer flashes a loading badge.
- Jumps received before document readiness are retained. Document/configuration generations reject stale completion callbacks and script messages. Footnotes and backlinks use the same controlled transition path. Existing imported files, preferences, portable progress schema, reader engine and platform availability remain unchanged.
- `Apps/macOS/CloudReaderTests/MacReflowReaderTests.swift`: real WebKit tests for stylesheet mutation, publisher smooth scrolling, fixed-viewport chrome changes, the chapter paint gate/native cover, a later destination during preparation, and SVG chapters. Existing selection, passage reflow, wheel and footnote checks remain in place.
- `Apps/macOS/CloudReaderUITests/MacReaderUITests.swift`: an application-level flow turns with the page button, advances a chapter, jumps back through the chapter menu and resumes paging.

No shared Apple production source, package resolution, XcodeGen setting or generated project was changed for this repair. The pre-existing dirty/untracked tree was preserved.

## Reproduction and verification

The two new regression tests were first run against the original implementation. Both failed, with three expected assertions: two stylesheet mutations during position/chrome changes, visible unconfigured chapter content, and no outgoing-page cover. The baseline output is retained as `Build/macOS/EPUBNavigationFix-20261024/red.log`.

The fixed implementation passed all **64 macOS runtime tests**. The five application UI scenarios all have passing results: four passed in the final combined run, and the new chapter-menu scenario passed on its focused rerun after correcting the test's macOS menu selector from `label` to `title`. That selector failure was in the test query, not an app failure. Earlier runs are superseded for that scenario.

Checks use the existing isolated `CLOUDREADER_TEST_HOST` / `CLOUDREADER_UI_TEST_MODE` infrastructure, temporary fixture libraries and unique preferences. The test app identifier is `io.github.haige120.cloudreader.macos.readerChecks`; tests omit sandboxing so bundled/check-out format fixtures can be read. No personal book library or sync destination was used.

```sh
xcodebuild -project Apps/macOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/CloudReader-EPUBTransitions-20261024 \
  -disableAutomaticPackageResolution \
  CLOUDREADER_APP_BUNDLE_IDENTIFIER=io.github.haige120.cloudreader.macos.readerChecks \
  ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

The focused chapter UI rerun adds:

```sh
-only-testing:CloudReaderMacUITests/MacReaderUITests/testEPUBPageButtonsAndChapterJumpsKeepMeasuredNavigation
```

Test-result summaries, logs and exported chapter-navigation screenshots are retained under `Build/macOS/EPUBNavigationFix-20261024/`. Xcode's WebKit subprocesses emitted system sandbox/XPC shutdown diagnostics; the successful tests did not report assertion failures or SwiftUI state-update runtime issues. Screenshots were visually inspected for the final chapter/spread layout. Intermediate-state regression checks verify the gate and native cover; they are not a high-frame-rate recording of every GPU frame.

## Local app artifact

The normal app build succeeds with the original `io.github.haige120.cloudreader.macos` identity, the project's app sandbox enabled, the existing macOS 15 minimum and ARM64 architecture. It is locally ad-hoc signed and remains version 1.1.0, build 2. The local test package is:

`Build/macOS/CloudReader-EPUB-Navigation-Fix-20261024.zip`

Both the built app and a clean extraction of that ZIP pass `codesign --verify --deep --strict`. `Build/macOS/EPUBNavigationFix-20261024/build-verification.json` records the archive hash, size, identity, architecture and entitlement verification. Existing app bundles and earlier archives were not replaced. This is a local test build; nothing was published or submitted.

The reader regressions use generated fixtures on the current Mac. The user's specific EPUB, other macOS versions and a personal-library upgrade remain outside that verification.
