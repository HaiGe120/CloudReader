# IOS-R02 — EPUB paging and styling

- Status: **integrated; wide-spread verification pending**.
- The iOS EPUB adapter normalizes the document viewport before measuring, uses snapped horizontal page/spread positions, exposes page range separately from chapter state, and restores from visible text anchors across layout changes. Shared shell actions and current EPUB security/resource restrictions remain in place.
- Verification: the iPhone Duo suite passed 112 tests with 2 skips and includes actual one-page EPUB swipe and cross-chapter swipe tests. EPUB WebKit and pagination tests passed in the suite.
- Limit: the simulator is narrower than 700 points, so its two-page EPUB swipe test skips. The iPhone Air landscape swipe has not run because Xcode requires the phone to be unlocked; see [IOS-R04](IOS-R04.md).

### 2026-10-21 reflow follow-up

The strengthened hide/restore/swipe UI check found and repaired a height-only appearance-cache invalidation bug in `EPUBBookReader.swift`. The renderer now reconfigures for chrome/height changes, preserves the previous page snapshot during reflow, and completes restoration when the visible-text anchor has settled. The regression test passes in `<local path>`; physical/wide spread acceptance remains with IOS-R04.
