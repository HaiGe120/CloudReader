# IOS-R01 — Common controls and appearance

- Status: **complete at simulator gate**.
- `BookReaderView` owns the single chrome visibility state, action sheets and capability selection. `ReaderChromeControls` owns progress/chapter/navigation controls. Appearance continues to use the existing keys in `ReaderAppearance.swift` and now reflects active adapter capabilities.
- Content taps hide and restore the navigation bar, toolbar actions, bottom controls and status bar; the shared container changes accessibility and releases the hidden inset.
- Verification: the full iPhone Duo UI suite passed 112 tests with 2 wide-layout skips; `testContentTapHidesAndRestoresReadingChrome` is included. The iOS device build and install passed.
- Limit: visual review on iPhone Air portrait/landscape awaits device unlock; see [IOS-R04](IOS-R04.md).
