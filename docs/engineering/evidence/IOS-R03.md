# IOS-R03 — Native interaction and reflow

- Status: **complete at simulator gate**.
- TXT retains a source-text offset through repagination. PDF callbacks are deferred past the UIKit view update and reject stale page/document state; hiding and restoring chrome does not recreate the PDF host or replace its current page. Native selection and zoom remain on the platform view.
- Verification: full iPhone Duo UI suite passed 112 tests with 2 wide-layout skips; PDF chrome/page preservation passed without runtime warnings. The generic iOS device build succeeded.
- Limit: on-device rotation/background/selection smoke remains part of IOS-R04 and is not claimed; see [IOS-R04](IOS-R04.md).
