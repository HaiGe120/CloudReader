# Current implementation and baseline audit

Audit date: **2026-10-20**. Scope: the current working tree, including uncommitted work.
Evidence comes from source, configuration, documentation, test inventory, and Git status.
**No builds, tests, project generation, provider requests, or app launches were run for this audit.**
“Present” below means implementation was inspected; it does not mean release validation passed.

## Follow-up status after the initial audit

The audit below records the starting state for the engineering plan. Foundation work has since
closed some of its findings:

- F01 repaired the canonical Apple project generation specs. Repeated generated projects were
  stable, both generated apps built, and the working-tree Mac project built. The duplicate plist
  and duplicate Xcode project remain preserved for a deliberate later cleanup decision; see
  [F01 evidence](evidence/F01.md).
- F02 isolated the current Apple test hosts and added a Mac test target. The disposable iOS
  simulator run passed 61 tests and the Mac run passed one contract test; see
  [F02 evidence](evidence/F02.md).
- F03 isolated Android import-test book files behind an injected directory and passed unit tests,
  lint, debug build, and isolated device instrumentation using the installed JDK/SDK; see
  [F03 evidence](evidence/F03.md).
- K04 exported the unchanged Android Room v1 schema, removed destructive fallback, and passed
  populated-database and unsupported-upgrade instrumentation checks; see
  [K04 evidence](evidence/K04.md).
- C01's v1 contract and 13 paired fixtures passed Draft 2020-12 schema validation and integrator
  review. Android consumes every fixture/expected pair in K01.b; Apple does so in S01.c. Remote
  Apple preflight rejects invalid hashes, names, numeric values, and versions before sync side
  effects. See [C01 evidence](evidence/C01.md), [K01.b](evidence/K01.b.md), [S01](evidence/S01.md),
  and [S01.c](evidence/S01.c.md).
- C02's integrator-reviewed merge target contains 12 semantic cases and its policy/vector
  inventory validates. Both Apple and Android implement the shared policy and their data-driven
  tests consume shared inputs and expected outcomes. Local gates pass; see [C02 evidence](evidence/C02.md),
  [S03 evidence](evidence/S03.md), and [K02 evidence](evidence/K02.md).
- A01 and K01 are complete. The Apple Core package now contains shared book, conversation, manifest,
  and AI profile values plus credential/profile ports; iOS and macOS builds and isolated test suites
  passed. See [A01.b evidence](evidence/A01.b.md). Android consumes all 13 schema-v1 fixtures,
  preserves opaque record fields across durable edits, and passes its unit/lint/build/instrumented
  checks; see [K01.b evidence](evidence/K01.b.md).
- S01 and K05 are complete. Apple retains unknown schema-v1 fields across manifest round trips,
  local persistence, edits and record replacement; package (13), iOS (62) and macOS (1) tests
  pass. Android library mutations use atomic field-level updates and durable tombstones; its 12
  unit tests, lint/build checks and 11 connected instrumentation tests pass. The old Android model
  duplicate is preserved byte-for-byte under [`Apps/Android/legacy/`](../../Apps/Android/legacy/)
  outside the compiled source tree. See [S01](evidence/S01.md) and [K05](evidence/K05.md).
- S01.c is complete. The Apple adapter now consumes all 13 shared fixtures, rejects invalid remote
  manifests before sync side effects, and preserves permissive legacy decoding for local records.
  Package tests (16), iOS simulator tests, and the macOS arm64 build pass; see
  [S01.c evidence](evidence/S01.c.md).
- A03 is complete at its code and automated-test gates. iOS and macOS use the shared async import
  coordinator, with durable inbox acknowledgment and mixed-result/retry tests. The current Apple
  suites pass 85 iOS and two macOS tests. Interactive picker/drop smoke with real OS file providers
  remains open; see [A03 evidence](evidence/A03.md).
- K03 is complete. Android sync construction and time are injectable; requests coalesce, selection
  and local-change triggers queue a fresh pass, destination outcomes remain visible, and provider
  resources close on success, failure, and cancellation. Seven focused tests and the full unit,
  lint, and debug-build check pass. Trigger wiring in the app remains K06; see
  [K03 evidence](evidence/K03.md).
- K06.a is complete. Foreground, local-change, provider-selection, and manual routes use the K03
  coordinator; provider selection is observed at app scope and its initial DataStore snapshot is
  skipped. Focused flow/coordinator tests and the full unit/lint/build check pass. Activity
  recreation was not device-tested. See [K06.a evidence](evidence/K06.a.md).
- K06.settings is complete. Settings values/actions now live in a lifecycle-aware ViewModel with
  an injectable store; persisted preferences, credentials, validation and provider selection
  retain existing behavior. Unit tests, lint and debug assembly pass; no on-device settings/auth
  smoke was run. See [K06.settings evidence](evidence/K06.settings.md).
- K06.assistant is complete at local automated gates. Assistant state/history/consent live in a
  lifecycle-aware ViewModel; opt-out removes saved context, and coroutine cancellation cancels
  the underlying OkHttp call. Focused and full Android unit/lint/build checks pass; live-provider
  and device recreation behavior remain unverified. See [K06.assistant evidence](evidence/K06.assistant.md).
- A04.b navigation is complete with shared chapter/document classification and native presentation
  handling. Bridge scripts and styles remain platform-owned because the current hosts differ in
  SVG, layout, viewport restoration, and progress behavior. The latest iOS suite passes 89 tests
  and macOS passes two; see [A04.b navigation evidence](evidence/A04.b.navigation.md).
- Android K07 TXT/PDF checkpointing now uses a thread-safe shared session controller and stable
  book-ID progress writes. K10.context reads the capped context incrementally. The latest Android
  unit/lint/debug-build check passes 51/51 unit tests; device lifecycle behavior remains open. See
  [K07.session](evidence/K07.session.md) and [K10.context](evidence/K10.context.md).

The initial-audit statements below are historical findings, not current claims about F01/F02.

## Working tree to preserve

Before these planning documents, `main` tracked `origin/main` with **22 modified tracked files
and 15 untracked status entries**; directory entries can contain multiple files.
This is an active implementation baseline, not a clean checkout of committed `main`.
A new worktree from `main` would omit important current functionality.

- Modified work includes shared models/library/sync; iOS reader, import integration and build
  configuration; Mac reader/settings and generated project; dependency locks; product docs.
- Untracked functional work includes iOS EPUB readers/parser, import coordinator, app
  entitlements, share extension/inbox, five test files, Mac EPUB reader, and ZIPFoundation license.
- Untracked duplicates: [`CloudReader 2.xcodeproj`](../../Apps/iOS/CloudReader%202.xcodeproj/)
  and [`Info 2.plist`](../../Apps/iOS/CloudReader/Info%202.plist).
  The duplicate project lacks newer EPUB tests and signing/App Group changes; the duplicate
  plist also differs. Review and archive deliberately after preserving the baseline; do not
  delete them merely because their names look accidental.
- The older [`BookImportCoordinator 2.swift`](../../Apps/Shared/BookImportCoordinator%202.swift)
  is also preserved on disk. Both canonical XcodeGen specs exclude it so only the current shared
  coordinator is compiled.
- No pre-existing `AGENTS.md` was found in the repository or its ancestor directories.

## Platform and feature inventory

| Platform | Current implementation | Baseline limitation |
| --- | --- | --- |
| iOS | SwiftUI, iOS 26+, PDFKit, native TXT, WebKit EPUB | Current reference; substantial work remains uncommitted |
| macOS | SwiftUI/AppKit, macOS 15+, PDFKit, TXT, WebKit EPUB | Shared services exist; generated project now verified by F01 |
| Android | Kotlin/Compose, API 31+, Room, AndroidX PDF, Readium EPUB | Existing native app; parity and live validation incomplete |
| Windows | [README stub](../../Apps/Windows/README.md) | No application or build configuration |
| Linux | [README stub](../../Apps/Linux/README.md) | No application or build configuration |

Apple apps consume the Foundation-only local [`CloudReaderCore`](../../Packages/CloudReaderKit/)
package for portable values, while app-specific views and services still compile from
[`Apps/Shared`](../../Apps/Shared/) and each platform target. Broad service extraction remains
planned. Android is one Gradle application module with Room-free `domain` values plus `data`,
`sync`, and `ai` packages.
There is no current web app, CloudReader account service, or hosted sync backend.

| Capability | Current code/status | Planned or unverified |
| --- | --- | --- |
| Offline library | Managed import copies, search, favorites, progress, demo book on three clients | Cross-platform durability matrix |
| Readers | TXT/PDF/DRM-free EPUB on current clients; iOS now shares the same shell across TXT/PDF/EPUB/FB2/CBZ | iPhone Air landscape spread verification is waiting for unlock; no cross-platform feature claim for FB2/CBZ |
| Other formats | MOBI/AZW3/CBR retained as files; FB2/CBZ have iOS adapters in the current working tree | MOBI/AZW3/CBR readers and iOS wide-device acceptance for EPUB/CBZ |
| Cloud sync | Schema-v1 index, hashed objects, tombstones, chats, multiple destinations | Concurrent-writer safety, explicit position conflicts, background transfers |
| Providers | Drive, Dropbox, pCloud, WebDAV, SFTP, platform-selected folders | Live authentication/provider matrix; additional direct adapters |
| AI | Three remote protocol shapes, optional context, saved conversations; local TXT/PDF context files are streamed up to 18,000 characters | Live-provider/error coverage, response streaming and tools |
| Apple integration | Foundation Models availability handling and App Intent | Device/system integration acceptance matrix |
| Annotations/export | Library favorite flag exists | In-book annotations/bookmarks and complete export/restore workflow |

The [product specification](../PROJECT_SPEC.md) and [iOS guide](../IOS_FIRST.md) describe
these features and existing limitations. Their historical test claims were not rerun here.
The current `isBookmarked` field is a library favorite, not an in-book bookmark.

## Source ownership and coupling

- [`Book.swift`](../../Packages/CloudReaderKit/Sources/CloudReaderCore/Book.swift) defines
  books/formats/deletions for both Apple apps.
- [`BookLibrary.swift`](../../Apps/Shared/BookLibrary.swift) combines persistence, import,
  mutations, merge application, context extraction, and a SwiftUI conversation-history view.
- [`RemoteStorage.swift`](../../Apps/Shared/RemoteStorage.swift) combines secure settings,
  OAuth, provider transports, manifest codec, and sync coordination in **1,539 lines**.
- [`AIService.swift`](../../Apps/Shared/AIService.swift) still combines remote protocol payloads,
  transport, and Apple on-device model integration; shared profile and conversation values now live
  in `CloudReaderCore`.
- iOS and Mac own separate reader/library/settings views; EPUB publication, resource, and link
  classification policies compile from `Apps/Shared`. WebKit hosts and bridge assets remain native;
  A04.b is complete at that refined boundary.
- Android's [`LibraryRepository`](../../Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/data/LibraryRepository.kt),
  [`SyncEngine`](../../Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/sync/SyncEngine.kt),
  and [`SyncCodec`](../../Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/sync/SyncCodec.kt)
  independently implement the same product/data behaviors.
- Sample text is checked in separately under `docs`, iOS resources, Mac resources, and Android
  assets. There is no deterministic shared-resource generation/checking entry point.

## Initial highest-priority risks and current disposition

**1. Unknown-field loss on Apple — closed by S01.** The product contract requires clients to retain
unknown optional metadata. The initial Apple codecs encoded only known keys while Android retained
extra root/book/chat/message/entry/tombstone properties. S01 adds opaque JSON preservation at these
Apple boundaries, durable round-trip coverage, and rejects unsupported schema versions. This verifies
local adapter behavior; live cross-platform provider sync remains a separate end-to-end check.

**2. Mac project generation lost EPUB configuration (closed by F01).** The checked-in
[`Mac project`](../../Apps/macOS/CloudReader.xcodeproj/project.pbxproj) manually includes
`../iOS/CloudReader/EPUBPublication.swift` and ZIPFoundation; the
starting [`Mac XcodeGen spec`](../../Apps/macOS/CloudReader.xcodegen.yml) included neither.
F01 added the missing source and ZIPFoundation dependency and verified stable generation and
builds from the generated projects.

**3. Existing tests could use the application's real stores (closed for the current suites by F02/F03).**
[`BookLibraryTests`](../../Apps/iOS/CloudReaderTests/BookLibraryTests.swift) instantiates
`BookLibrary()` for import/history checks and mutates `UserDefaults.standard` for provider
selection in the starting tree. F02 now gives the current Apple tests temporary storage/preferences
and isolated test hosts, verified by the runs cited above. Android's `LibraryImportTest` previously
deleted `targetContext.filesDir/CloudReader/Books`; F03 now injects a temporary root, with unit,
lint, build, and isolated instrumentation verification recorded in its evidence.

**4. Android mutation and crash-consistency hazards — closed by K05.** The initial repository
removed bytes before persisting its tombstone, ignored file-rename failure, and applied stale full-row
snapshots. K05 replaces these with field-level updates, tombstone-first deletion, checked staged
installation and a current-state recheck in the database transaction. Focused instrumentation tests
cover concurrency and interrupted operations; see [K05 evidence](evidence/K05.md).

**5. Android migration policy could discard local state (closed by K04).**
[`CloudReaderDatabase`](../../Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/data/CloudReaderDatabase.kt)
is version 1, disables schema export, and configures `fallbackToDestructiveMigration(false)`.
K04 exports the unchanged v1 schema and removes destructive fallback. Existing populated v1 data
opens unchanged, and an unsupported upgrade fails while retaining the prior data. See
[K04 evidence](evidence/K04.md). Every future schema version still requires an explicit tested
migration.

**6. Sync integration now has isolated failure coverage, but not cross-device writer safety.**
S02 and K03 add injectable fake-store tests for retries, partial destination failure, missing or
corrupt objects, local edits during suspended transfers, cleanup, and latest-state publication.
Android K02 and Apple S03 implement the same deterministic merge policy and preserve local recovery
candidates. Their paired tests build cases from shared vector inputs and expected values, and local
policy/platform gates pass. Both clients still use unconditional v1 read/merge/write manifests, so
concurrent writers can lose unseen updates. Live provider and two-device round trips remain
unverified.

## Build, test, and delivery evidence

- Canonical Apple build inputs are the two XcodeGen specs, with generated projects and
  `Package.resolved` committed. F01 verified the generated projects; see its evidence for hashes
  and build results.
- Android commits its Gradle wrapper, wrapper checksum, versioned plugin/dependency declarations,
  and `app/gradle.lockfile`; its supported commands are in the [Android README](../../Apps/Android/README.md).
- The initial audit found **61 iOS test methods in six app test files** covering local
  library/import, pagination, EPUB archive/cache/navigation/security, WebKit reading, and the
  shared inbox. F02 isolated those hosts; later A01 package tests are tracked in its evidence.
- F02 added a Mac test target and contract test; its current evidence records one passing test.
- The initial Android inventory had **nine unit tests and one import instrumentation test**.
  F03 verified those targets; K04 added two isolated migration instrumentation tests.
- C01 provides an external JSON Schema and shared fixture set. K01.b and S01 consume the same
  fixture inputs on Android and Apple; adapter conformance passes for the covered cases. Live
  provider sync and concurrent-writer outcomes remain unverified.
- No CI workflows were found. F03 added root Android check scripts, but shared-source changes still
  have no automated gate requiring both Apple targets or all schema consumers to pass.
- The initial audit found a malformed root README Mac command; F01 corrected it. The baseline
  third-party notices also describe ZIPFoundation as iOS-only and omit Android dependencies.
- Build/test success, live OAuth/token refresh, two-device sync, real-device accessibility,
  signing/install/update behavior, and release readiness remain **unverified by this audit**.

The working tree remains an active uncommitted implementation baseline. Foundation/build/test
isolation, K04 migration safety, C01/C02 contract design, Android K01/K02/K03/K05/K06.a/library/settings,
K07 controller and K10.context, and Apple A01/A02/A03/A04.a/A04.b/A05/S01/S01.c/S02/S03 are complete
at their documented local gates. The latest integrated iOS suite passes 89 tests, the macOS suite
passes two, and CloudReaderCore passes 26. Android unit/lint/build checks pass with 51 unit tests,
and the latest connected instrumentation run passes 15 emulator tests.
Device lifecycle and remaining feature parity checks are still open. Other parity work remains planned. Live providers,
cross-device concurrent-writer safety, interactive import UI, reader accessibility matrices, and
release/update flows remain unverified by these checks.
