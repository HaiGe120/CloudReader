# IOS-F04 — Streaming CBR preparation

Status: **preparation passes the local integration gate; public reader availability remains gated by IOS-R04**.

Baseline: preserved dirty/untracked tree. Original imports, local library data and shared schema/capability flags are unchanged.

## Implementation

- `Apps/Shared/CBRPublication.swift` advances one UnRAR handle sequentially, including solid archives. `RAR_TEST` streams decompressed chunks into the app's bounded staging writer; UnRAR does not write a second copy into its working directory. The preparation source moved from iOS during M01.reader; platform availability remains separate.
- Archive entries reject absolute/traversal paths, ambiguous duplicates, links, encryption and split volumes. Limits remain 10,000 entries, 64 MiB/image payload, 1 GiB total output and a 64 MiB dictionary. ImageIO checks page dimensions without decoding every full-size image during preparation.
- Cancellation reaches the active image-data callback. A cancelled/failed preparation does not publish a completion marker. The test callback barrier has a timeout, so a pre-callback failure remains a test failure rather than hanging the suite.
- Output uses the existing ordered comic publication and cache. `CBZBookReader` accepts a CBR source format, but the shell still routes CBR to its unavailable reader pending acceptance. Comics keep their original artwork.
- Unrar.swift 0.5.4 is pinned to `7216007a38ac122dbdeae26cfdaf7f10775c868f` in the XcodeGen spec/resolution. MIT/UnRAR notices and test-fixture attribution/licenses are retained. The coordinator owns project generation.

## Verification

2026-10-21: all **9 CBR tests passed** in `<local path>`, within the integrated **136 passed, 3 width skips, 0 failed** suite on iPhone Duo / iOS 27.1.

Coverage: real image extraction from RAR4/RAR5 solid and nonsolid archives; natural ordering; unrelated-entry skipping before a solid page; corrupt/no-image input; per-page/total/entry/dictionary limits; active callback cancellation; encrypted files/headers; split volumes; absolute directory paths; RAR5 symlinks; completion markers and original-byte preservation. RAR4 solid extraction was verified by the actual UnRAR XCTest, not inferred from a ZIP or a header-only fixture.

XcodeGen generation, Swift parsing and the signed simulator/device builds passed. For the exact full-suite command see [IOS-F03](IOS-F03.md). A focused rerun can select `-only-testing:CloudReaderTests/CBRPublicationTests` with a fresh result-bundle path.

Remaining: CBR reader UI opening/resume/zoom/pan/swipe acceptance and the physical/wide IOS-R04 gate. Native comic interaction reuse does not establish those unrun checks. Do not mark this card done or enable CBR from preparation tests alone.
