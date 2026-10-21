# IOS-F02 — CBZ reader

- Status: **implemented; wide-device interaction gate pending**.
- `CBZBookReader.swift` uses ZIPFoundation and an ordered, zoomable native image-page adapter. It validates archive paths and encryption, caps entries and image/unpacked sizes, downsamples through ImageIO, caches decoded pages within a 64 MiB budget, preserves source bytes and stores prepared pages only in disposable cache.
- `CBZPublicationTests.swift` covers numeric ordering, odd spreads, page-index alignment, unsafe paths, original-byte retention/cache reuse, encryption, corrupt/non-image input and size limits. The iPhone Duo UI suite passed 112 tests with 2 wide-layout skips and includes the actual one-page comic swipe.
- Limit: the odd final wide spread was skipped below the 700-point threshold. Add a real pinch/pan interaction check and run the wide CBZ spread/swipe test after the iPhone Air is unlocked; see [IOS-R04](IOS-R04.md).
