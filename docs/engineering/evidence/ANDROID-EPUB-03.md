# Android EPUB controls and appearance — 2026-10-24

Scope: the K08 appearance-controls child requested by the user. Retain Readium 3.4.0 and the existing native app. This does not close the remaining K08 restoration/selection-to-AI work.

## Behavior

- EPUB opens with the toolbar and system bars hidden. There is no floating Show controls chip over the page. A tap in the middle 40% horizontally and middle 50% vertically toggles the compact toolbar. Edge taps remain Readium navigation; links and selection are processed before unhandled reader taps. Root accessibility actions also toggle the toolbar.
- **Aa** opens a native, scrollable panel for serif/sans/monospace fonts, 14–38 text size, System/Light/Sepia/Dark/Custom page colors, scrolling, one page and two pages. Changes apply immediately and persist through the existing preferences adapter. Typography/colors share the existing TXT keys; EPUB uses `reader.epub.layout` and leaves TXT pagination separate.
- Two pages request two actual columns at widths of at least 600 dp; compact screens retain the choice and show one column. Readium's public `RsProperties.overrides` hook makes its column variables follow the explicit adaptive preference. Configuration changes reapply preferences to adapt when the window crosses that width. Fixed-layout EPUBs retain publisher typography.
- Reflow retains Readium's current locator. Production progress uses the existing ReaderSession with latest-row lookup and a lifecycle flush, preserving other book metadata.
- NativeReaderChrome flags default to the previous PDF behavior. TXT/PDF keep their existing restore affordance.

## Owned paths

`Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/{EpubReaderActivity,EpubReaderHost,EpubReaderAppearance,EpubAppearanceDialog,NativeReaderChrome}.kt`; corresponding appearance policy, real-publication host and native shell tests; Android build version/README; this evidence. No database/schema/dependency/signing changes.

## Verification

Android gates use JDK 17 and an isolated build directory outside the synced checkout:

```sh
./gradlew --console=plain --no-build-cache \
  -I /tmp/cloudreader-epub-appearance-20261024/isolated-build.init.gradle \
  testDebugUnitTest lintDebug assembleDebug connectedDebugAndroidTest
```

- 121 JVM tests pass. Fourteen new appearance-policy cases cover validated settings, font mapping, colors and adaptive page modes.
- Lint: 0 errors, 30 warnings, 1 hint.
- Android 17/API 37 isolated ARM64 emulator, 1840×2208 at 420 dpi: 27 instrumented tests pass. Two new real Readium/WebView tests assert hidden startup/no overlay, center-tap recovery, edge page turns, actual computed font/colors/size, scrolling overflow, rendered column count and locator retention. Existing import, durability, schema/contract, TXT and PDF checks pass.
- At 1080×2092/420 dpi, all 8 EPUB/native shell/TXT/PDF reader tests pass, including the compact one-column fallback.
- Manual production flow imports the original Quiet Pages EPUB through the Android picker, opens fully hidden, exposes the toolbar by center tap and opens Aa. Sepia/Mono/21 pt/Two pages persist after closing and reopening. Edge navigation advances to passage 5, which reopens correctly. Live resizing from compact to wide renders two columns; resizing back renders one while retaining the passage. Screenshots and the manual report are retained in `Build/Android/Review/epub-1.0.2/manual/`.
- First run was blocked by Android's first-use immersive-mode tutorial taking focus. Acknowledged the system tutorial and reran the unchanged tests; all passed. No assertions were weakened.

Build/test logs and recovery checkpoint: `/tmp/cloudreader-epub-appearance-20261024/`. The pre-change tracked patch, status and Android source archive preserve the existing dirty checkout. Publication uses a separate Git index parented to Android preview 1.0.1; the user's current HEAD/index are retained.

## Limits

These are emulator and source checks, not proof on a physical Pixel Fold. EPUB process-death recreation still exits to the library for a persisted-location reopen, as before this change. The remaining K08 recreation and selection-to-AI tasks are not claimed complete. Live provider authorization and cross-device sync were not part of this EPUB repair.

The existing portable progress-percentage policy uses Readium's `totalProgression`, which can be coarse. In the single-resource fixture, Readium returned totalProgression 0.5 alongside resource progression 0.037037; the exact stored locator restored passage 5 correctly. This preexisting percentage-estimation behavior is retained and is distinct from precise local passage restoration.
