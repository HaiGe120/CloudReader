# IOS-F03 — Offline MOBI/AZW3 preparation

Status: **preparation passes the local integration gate; reader availability remains gated by IOS-R04 and iPhone performance verification**. This is not a completed physical-device acceptance record.

Baseline: the preserved dirty/untracked CloudReader tree. No original book, library record, preference key, credential, or schema-v1 representation was migrated.

## Implementation

- `Apps/iOS/CloudReader/KindlePublication.swift` validates PalmDB record tables, record-relative MOBI header fields, supported encoding/compression, EXTH lengths, and both halves of combo files. DRM is rejected before decoder invocation. MOBI6 dictionary headers, fixed-layout metadata, print-replica payloads and non-MOBI containers are rejected.
- `KindleDecoder/` contains the pinned Foliate `mobi.js` and fflate 0.8.2, an offline conversion harness and retained notices. A restricted custom scheme serves only those bundled files; the isolated, nonpersistent WebKit context cannot fetch external content.
- Conversion exports local chapters, images and CSS, rewriting Kindle position/resource links into validated local paths. Output bounds count UTF-8 bytes. Concurrent conversions are serialized, cancellation is scoped to the active conversion, and a post-conversion cache check handles actor reentrancy.
- Preparation writes disposable staging output and a final completion marker. `EPUBBookReader` can consume the prepared publication through its `sourceFormat`; the shell still routes MOBI/AZW3 to the unavailable reader until the remaining gates pass. Shared macOS format capability flags remain unchanged.
- Project/test resource wiring is in `Apps/iOS/CloudReader.xcodegen.yml`; fixture resources use explicit `buildPhase: resources` entries. Test-only fixture notices and licenses are retained beside the files. No decoder generator dependency is linked into the app.

## Verification

2026-10-21, iPhone Duo simulator, iOS 27.1 (24A94425), UDID `22A96429-4799-42C6-A662-064EB20A582E`:

- Full integrated suite: **136 passed, 3 width-dependent UI skips, 0 failed, no runtime warnings**, result `<local path>`.
- Kindle coverage includes real MOBI6 image bytes and file-position links; independent KF8 and combo chapter content; HUFF/CDIC decompression; PalmDOC-compressed KF8 Chinese text, images, CSS and cross-chapter links; primary/secondary DRM rejection; dictionary/fixed-layout/print-replica rejection; truncated containers; concurrent cache use; and original-byte preservation.
- `node --check Apps/Shared/KindleDecoder/converter.js`: passed (decoder resources moved to `Apps/Shared` during M01.reader).
- `xcodegen generate --spec Apps/iOS/CloudReader.xcodegen.yml`: passed.
- Signed generic iOS device build: passed with `<local path>` as derived data.

The integrated test command, from the repository root:

```sh
xcodebuild -quiet -project Apps/iOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'platform=iOS Simulator,id=22A96429-4799-42C6-A662-064EB20A582E' \
  -derivedDataPath <local path> \
  -resultBundlePath <local path> \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=YES CODE_SIGNING_IDENTITY=- test
```

Remaining: physical iPhone memory/performance and lifecycle measurements, reader opening/selection/swipe acceptance through the enabled shell, and the IOS-R04 wide/physical gate. Simulator timings are not iPhone performance evidence. Do not enable MOBI/AZW3 or mark this card done from this record alone.
