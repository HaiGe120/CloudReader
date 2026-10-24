# M01.reader — EPUB spread alignment

Status: implemented and verified locally, 2026-10-24. This bounded follow-up addresses the user's screenshot of previous-page text appearing at the left edge and clipped right-page text late in an EPUB chapter. The earlier flashing repair remains documented in [M01-EPUB-NAV-01](M01-EPUB-NAV-01.md).

## Cause and implementation

For viewport width W, N columns and gutter G, the existing CSS produces column width C = (W − (N−1)G)/N. Overflow columns advance by C+G, so one complete spread advances by N(C+G) = W+G. The JavaScript used W. With the 28-point facing-page gutter, turns accumulated 28, 56 and 84 points of drift by spreads 2, 3 and 4.

`Apps/macOS/CloudReader/MacEPUBBookReader.swift` now measures the body width and distinguishes column pitch from spread stride. Progress restoration, passage/fragment jumps, native turns, keyboard turns and page reporting use that same geometry. Fragment destinations align to the containing spread. Explicit page/seek actions clear any previous fragment destination.

The logical maximum offset comes from actual content columns. An invisible absolute extent marker outside the body supplies the blank right half of an odd final spread without entering the multicolumn content or adding a fake page. Content measurement includes images and other media, with cache invalidation for changed content geometry and during initial reflow. No shared Apple source, schema, preferences, dependencies or project configuration changed.

## Regression and book verification

`MacReflowReaderTests.testSpreadOriginsRemainAlignedThroughLongChaptersAndOddLastPages` uses generated eight-page, seven-page and image-only chapters. It checks native-turn entry points, keyboard turns, end-of-chapter progress seeks, boundaries, second-column fragments, a fractional-width resize, switching to single-page layout and a late media-layout change.

Before the repair, the test observed offsets 800/1600/2400 where the rendered column grid required 828/1656/2484, and reproduced odd-last-page clamping, unsnapped fragments and image-only page-count errors. The baseline log is retained under `Build/macOS/EPUBAlignmentFix-20261024/red.log`.

A copy of the reported chapter “学会热爱阅读” from the matching 66-chapter book was staged in temporary storage with only its two linked stylesheets. The same alignment test also ran against that copy, including pages 7–8, final-spread positioning, resizing and single-page mode. Its screenshot was exported and visually inspected: both page margins are aligned and the previous-column sliver is absent. The personal app, original imported EPUB, library index, preferences and personal cache were not changed by validation.

The optional staged-book inputs are `CLOUDREADER_EPUB_ALIGNMENT_ROOT` and `CLOUDREADER_EPUB_ALIGNMENT_CHAPTER`; they are injected only into an isolated temporary `.xctestrun`. They are not required for the portable generated-fixture regression.

## Checks and limits

- Final macOS runtime suite: **65 tests passed, zero failures**, including all five reflow tests and the staged reported chapter. Summary: `Build/macOS/EPUBAlignmentFix-20261024/runtime-summary.json`.
- All **five application UI scenarios have current passing results**. The UI suite passed the EPUB page-button/chapter-menu flow, wide spread wheel/chrome flow, narrow EPUB/TXT flow and comic/PDF flow. Its first multi-format smoke scenario initially encountered launch/hidden-controls timing failures; the unchanged assertions passed in a separate focused rerun. `ui-summary.json` retains the failed grouped attempt and `formats-ui-summary.json` records the passing rerun. A launcher cleanup explicitly terminates any remaining isolated test-host process before starting the UI session. No assertions were weakened or tests disabled.
- Tests use the existing isolated reader-check app identity, unique temporary libraries/preferences and no personal sync. Test builds omit sandboxing solely to access checkout fixtures. No personal-library upgrade or older-macOS runtime check was performed.
- Screenshots, logs and result summaries are under `Build/macOS/EPUBAlignmentFix-20261024/`. The renderer was checked with actual WebKit; static screenshots establish final layout, not every intermediate GPU frame.

Reproduction uses the existing `scripts/check-macos-reader.sh unit` and `ui` modes. Focused alignment check:

```sh
xcodebuild -project Apps/macOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/CloudReader-EPUBTransitions-20261024 \
  -disableAutomaticPackageResolution \
  -only-testing:CloudReaderMacTests/MacReflowReaderTests/testSpreadOriginsRemainAlignedThroughLongChaptersAndOddLastPages \
  CLOUDREADER_APP_BUNDLE_IDENTIFIER=io.github.haige120.cloudreader.macos.readerChecks \
  ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

## Local artifact

`Build/macOS/CloudReader-EPUB-Page-Alignment-Fix-20261024.zip` is a fresh normal app build with the original bundle identity, sandbox enabled, macOS 15 minimum and ARM64 architecture. Existing version 1.1.0/build 2 is retained. The archive contains no XCTest bundles or staged private book data. The built app and a clean ZIP extraction pass strict deep signature verification; `build-verification.json` records the SHA-256 and entitlement checks. The earlier navigation-fix archive is preserved. This is a local ad-hoc signed build; no release or store submission was made.
