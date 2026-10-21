# IOS-R00 — Freeze and separate reader adapters

- Status: **complete at integration/build gate**.
- Frozen contracts: `ReaderCapabilities`, `ReaderLayoutMetrics`, `ReaderNavigationState`, uniquely identified `ReaderNavigationRequest`, `PreparedPublication` and the shared content-tap callback. These moved from the iOS target to `Apps/Shared/ReaderContracts.swift` during M01.reader so both Apple shells use the same contract.
- Extracted native TXT/PDF and selectable-text hosts to `Apps/iOS/CloudReader/NativeBookReaders.swift`; `BookReaderView.swift` now composes adapters through the frozen interfaces. XcodeGen remains canonical; generated project wiring was regenerated.
- Verification: `xcodegen generate --spec CloudReader.xcodegen.yml` succeeded; Swift reader source parsing, generic iOS device build and the full iPhone Duo suite passed. The full suite result was 112 passed, 2 wide-layout skips, 0 failures.
- Limit: device UI acceptance and landscape spread behavior are tracked in [IOS-R04](IOS-R04.md); this card does not claim them.
