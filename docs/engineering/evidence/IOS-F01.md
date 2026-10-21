# IOS-F01 — FB2 reader

- Status: **complete at unit and simulator gates**.
- `FB2Publication.swift` converts namespace-aware XML events to a disposable local HTML publication for the shared reflow renderer. It retains inline order, semantic structure, local embedded images and note links, disables external entities, validates inputs and writes through staging plus a completion marker. Original FB2 bytes and v1 book records are unchanged.
- `FB2PublicationTests.swift` covers UTF-8 mixed content/escaping, declared Latin-1, images/notes/external links, malformed XML, generated paths, cancellation and original-byte preservation. The full iPhone Duo suite passed 112 tests with 2 wide-layout skips and includes the FB2 open test.
- Limit: the enclosing R04 physical-device reader gate remains open; see [IOS-R04](IOS-R04.md).
