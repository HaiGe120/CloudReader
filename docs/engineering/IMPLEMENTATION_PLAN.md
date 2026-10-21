# CloudReader implementation plan

Prepared 2026-10-20. Foundations and the shared v1 contract are complete. A01/A02/A03, A04.a/A04.b, A05, S01/S01.c/S02/S03, K01/K02/K03/K04/K05/K06.a/K06.library/K06.settings/K06.assistant, K07.session, and K10.context have passed their documented local gates. Current checks pass: CloudReaderCore 26 tests, iOS 89, macOS 2, Android 51 unit tests plus lint/debug build, and 15 connected Android instrumentation tests. Live provider sync, two-device conflict behavior, interactive import UI, and reader lifecycle behavior on devices remain unverified. **Next: continue bounded Apple service extraction (A06/A07/A08) and Android reader/import/adaptive parity (K07 device checks/K08/K09/K10 end-to-end), split into small owned-path tasks.** Read [architecture](ARCHITECTURE.md) for boundaries and [agent workflow](AGENT_WORKFLOW.md) for handoffs and check definitions.

## Milestones and order

| Milestone | Deliverable | Exit condition |
| --- | --- | --- |
| 0. Preserve and reproduce | Current EPUB/share-import work safely captured; reliable project generation and isolated tests | F00–F03 pass or record pre-existing failures with a reproduction |
| 1. Freeze compatibility | First Apple package boundary, safe Android schema baseline, one v1 contract and shared fixtures | A01/K04 and C01/C02, S01/K01 complete; both languages consume identical fixtures |
| 2. Establish boundaries | Remaining Apple package/services; Android repository/ViewModel/session boundaries | A02–A08, S02/S03, K02–K07 complete with affected checks |
| 3. Reach product parity | iOS reference hardened, macOS aligned, Android import/reader/assistant parity | I01/M01/K08–K11; UI/device scenarios verified |
| 4. Integrate and recover | Efficient transfers, export/restore, CI and real cross-platform validation | O01/O02/Q01/Q02 pass; release evidence distinguishes live vs simulated checks |
| 5. Add desktop clients | Windows/Linux shared desktop implementation and OS integrations | D01–D06 pass on their respective operating systems |
| 6. Evolve protocol/features | Reviewed v2 migration, exact locations, conflict UI, annotations | X01 design accepted by integration review; separately scoped implementation |

iOS is the product reference, including the current uncommitted EPUB and share extension work after verification. macOS must follow its visual family. Android's native controls can differ while matching behavior and portable data meaning. Windows/Linux begin after the existing clients are reliable; their current folders are placeholders.

Do not execute this entire document as one coding prompt. A task involving both languages or multiple unrelated feature files must be split into suffixed child cards before dispatch. Child cards inherit the parent dependencies and add an explicit owned-path list.

Task ownership below uses **integrator** for the coordinating agent and **worker** for a bounded coding agent. Check IDs are defined in the workflow. `K/` abbreviates `Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/`; `KT/` abbreviates the corresponding `src/test/kotlin/io/github/haige120/cloudreader/`. A task owns its listed production paths plus relevant isolated tests; broad directory permission is not permission to rewrite that directory.

## Foundation

### F00 — Preserve current work and record the baseline

- Status: **done**. Evidence: [F00 baseline](evidence/F00.md).
- Depends: none. Owner: integrator. Paths: repository inventory and `docs/engineering/evidence/` only until preservation is complete.
- Record branch/commit, tracked modifications and untracked functional files. Capture a recoverable local snapshot including new EPUB/share/import/tests; check for secrets and generated junk before any checkpoint commit. A fresh worktree from `main` is insufficient. Do not reset/stash away current work or delete duplicate artifacts.
- Inspect available tools, simulators/devices, dependency caches, and signing state. Run baseline checks in a preserved staging copy where generation/tests cannot damage the current working tree or real library. Record original-project builds separately from clean-generation failures.
- Done: snapshot can be restored, functional untracked sources are included, baseline results identify existing failures. Gate G0. Dependent tasks may proceed around a recorded unrelated failure, but must not claim a green baseline.

### F01 — Repair Apple build reproducibility

- Status: **done**. Evidence: [F01 generation and build results](evidence/F01.md).
- Depends: F00. Owner: integrator. Paths: both XcodeGen specs/projects/schemes, relevant package resolutions, platform build docs, future `scripts/check-apple.*`.
- Add the Mac EPUB source/dependency currently present only in its project to its generator spec as an interim fix. Preserve iOS share-target/App Group/test wiring. Compare duplicate project/plist contents and archive only confirmed obsolete copies after their unique work is preserved. Fix competing/broken build instructions.
- Keep generator/toolchain versions explicit. Regenerate in isolation, prove generated projects include all targets/resources/EPUB dependencies, and inspect the diff. No unrelated SDK/dependency upgrades or signing identity changes.
- Done: a second generation is stable and both Apple apps build from specs; share extension remains embedded. GAPPLE build portion plus generation comparison. A04 later removes the temporary cross-app EPUB source reference.

### F02 — Isolate Apple tests and add the Mac test host

- Status: **done**. Both Apple test hosts are isolated, all 61 iOS tests and the initial macOS contract test passed; see [F02 evidence](evidence/F02.md). Broader adapter coverage remains in later work packages.

- Depends: F01. Owner: integrator for target wiring; worker for tests. Paths: Apple test targets, test utilities, `BookLibrary`/sync dependency injection only where necessary.
- Replace tests using default application storage or `UserDefaults.standard` with temporary directories and unique suites. Run against an isolated process/container until all tests are isolated. Add a macOS test target for shared/native adapter cases; preserve all existing iOS regression cases.
- Done: repeat tests without changing the user's app library/settings; cleanup runs on failure. Existing iOS tests execute, Mac can run a test target. GAPPLE and GDATA. Do not treat test-source existence as a passing result.

### F03 — Make Android checks reproducible

- Status: **done**. The import test uses an isolated file root; root check scripts, platform instructions, and successful unit/lint/build/instrumentation results are recorded in [F03 evidence](evidence/F03.md). The installed JDK and Android SDK were selected explicitly for these checks.
- Depends: F00. Owner: worker. Paths: Android build documentation, future `scripts/check-android.*`, import test/file-root injection and test-runner configuration.
- Record wrapper/JDK/SDK requirements from current build; preserve dependency locks. Provide repeatable unit/lint/debug-build commands and a separate instrumentation command with an explicitly selected test device. Do not reinstall tools already present.
- First isolate `LibraryImportTest`: its in-memory database currently still deletes the target application's managed Books directory. Inject a temporary file root and clean up only that root; preserve production defaults. Do this before running instrumentation against an installation with user data.
- Done: GANDROID runs or reports a concrete environment blocker; instrumentation uses isolated files/database and is labeled separately. No user-visible behavior change; test seams may be added.

## Portable contract and sync

### C01 — Create the executable schema-v1 contract

- Status: **done**. The reviewed v1 contract, Draft 2020-12 schema, repeatable validator, and 13 paired fixtures are in [`Contracts/v1/`](../../Contracts/v1/README.md); schema validation passes. Swift/Kotlin adapter adoption is complete in S01/K01. See [C01 evidence](evidence/C01.md).

- Depends: F00. Owner: integrator. Paths: new `Contracts/v1/`, product spec's contract links.
- Define required/optional/default/null behavior, Foundation dates, UUID/object names, hash/path rules, finite progress, unknown payload preservation, conversation context, tombstones, and unsupported-version behavior. Use current valid v1 files as compatibility examples; document malformed-input rejection without silently tightening valid legacy fields.
- Add shared JSON fixtures for minimal/legacy/full records, nested unknowns, unknown formats/enums, deletion/equal time, mixed UUID case, fractional timestamps, corrupt hash, unsafe filenames, invalid numbers, and unsupported version. Expected semantic results accompany fixtures.
- Done: fixtures validate against the declared schema and have explicit expected semantic results and an adoption map for both language suites. Adapter conformance is covered by S01/K01; C01 does not require already-fixed adapters. No v2 fields or silent merge-algorithm change.

### A01 — Establish the first Swift package boundary

- Status: **done**. A01.a and A01.b establish the first shared Swift package boundary; both Apple apps and isolated suites pass. See [A01.a evidence](evidence/A01.a.md) and [A01.b evidence](evidence/A01.b.md).
- Parent dependencies: F01/F02/C01. Keep package/project wiring under one owner at a time. Preserve current local JSON and remote wire keys; unknown-field conformance remains S01.

#### A01.a — Bootstrap `CloudReaderCore` with book values

- Status: **done**. See [A01.a evidence](evidence/A01.a.md).
- Depends: F01/F02/C01. Owner: worker for extraction; integrator reviews project wiring. Paths: new `Packages/CloudReaderKit`, `Book`/`BookFormat`/`BookDeletion` declarations, the two XcodeGen specs and generated project files, only the source imports/call sites required to use the package, package tests.
- Move the existing book value types into a Foundation-only `CloudReaderCore` package and make both Apple apps consume the package definition. Preserve Codable keys/defaults, library paths, object naming and app behavior. Keep shared-source worktree changes intact, including share extension and EPUB wiring.
- Done: package tests prove legacy defaults, Codable keys, fractional Foundation-date values, and UUID/object-name behavior; both Apple apps generate/build and their test suites pass. No UI/PDFKit/Keychain imports or unknown-field behavior changes.

#### A01.b — Move conversation and manifest values into Core

- Status: **done**. Conversation, manifest, and AI profile values live in Core; typed profile/credential ports are consumed through app-owned adapters, and both Apple app lanes pass. See [A01.b evidence](evidence/A01.b.md).
- Depends: A01.a. Owner: worker for model move; integrator owns package/project manifest changes. Paths: conversation declarations in `AIService.swift`, manifest declarations in `RemoteStorage.swift`, new Core model files/tests, and only required imports/call sites.
- Move `AIConversationMessage`/`Record`/`Deletion`, `SyncedBook`, and `RemoteLibraryManifest` into Core. Define the minimal profile/credential ports required by AI services, leaving current vault/provider implementations in app targets. Preserve current Codable behavior and do not extract transports or coordinators.
- Done: one declaration per shared type is used by both apps, the package remains Foundation-only, existing persistence/wire output decodes unchanged, and both Apple apps/tests pass. Unknown-field preservation remains S01; provider extraction remains A07.

### S01 — Preserve unknown schema-v1 data on Apple

- Status: **done**. Apple fixture preservation and durable persistence pass. See [S01 evidence](evidence/S01.md).
- Depends: A01/C01. Owner: worker. Paths: Swift wire DTO codecs, local persistence mappings, contract tests.
- Preserve extras through decode, durable save/reload, known-field edits, replacement and re-encode at every C01 boundary. Maintain a lossless opaque representation for unknown optional payloads. Do not couple domain views to JSON dictionaries.
- Done: golden fixtures retain unknowns across a local round trip; a real edited known field changes while extras remain; unsupported versions cannot be published. Package (13), iOS (62), and macOS (1) tests pass. Existing app versions still have this limitation; do not claim the change repairs old binaries.

### S01.c — Complete Apple shared-fixture preflight coverage

- Status: **done**. Apple consumes every shared fixture pair and validates the full remote manifest before sync side effects. See [S01.c evidence](evidence/S01.c.md).
- Depends: C01/S01. Owner: worker. Paths: Core remote-manifest validation, its sync preflight call site, and shared-fixture tests.
- Consume all 13 input/expected pairs directly from `Contracts/v1/fixtures`. Keep characterization cases separate from normative rejection/preservation checks. Reject invalid remote hashes, unsafe names, invalid numeric bounds and unsupported versions before applying tombstones, touching local files, downloading objects or publishing. Keep legacy local decoding compatible; do not change merge policy.
- Done: one Apple test reads every shared input/expected pair; remote sync validates the entire decoded manifest before any mutation or provider write; characterization notes accurately describe current behavior. Package (16), iOS simulator tests, macOS arm64 build, and fixture/schema/vector validation pass.

### K01 — Adopt the shared contract fixtures on Android

- Status: **done**. K01.a and K01.b are complete; shared-fixture, durable unknown-data, and Android adapter checks passed. See [K01.b evidence](evidence/K01.b.md).
- Depends: F03/K04/C01. Owner: worker, split into K01.a/K01.b. Paths: `K/domain`, existing `K/data/Models.kt`, explicit storage/wire mappings, `K/sync/SyncCodec.kt`, `KT/sync`, test fixture configuration.
- K01.a separates domain values/ports, Room entities and wire DTOs without changing Room table definitions/version. Break the current entity↔codec dependency: merge logic uses Room-free values, and explicit adapters map storage/wire records. **Done:** these boundaries and transactional snapshots pass Android unit/lint/build and isolated instrumentation checks; see [K01.a evidence](evidence/K01.a.md).
- K01.b replaces duplicated inline examples with shared fixture consumption and closes C01 gaps including durable unknown data and safe unknown optional formats. Preserve valid existing v1 records. **Done:** all 13 shared fixture pairs are consumed directly; six Android instrumentation tests pass, including durable unknown-field save/reload/edit. See [K01.b evidence](evidence/K01.b.md). Merge vectors remain K02.
- Done: Android matches the shared v1 fixture classifications and preserves tested legacy defaults/date precision/object names. Apple S01 now passes the same nested-unknown fixture; production merge vectors are adopted under the paired S03/K02 milestone. GCONTRACT/GANDROID.

### C02 — Specify deterministic merge cases

- Status: **done**. Integrator-reviewed target policy and 12 semantic vectors are in [`Contracts/v1/merge-vectors.json`](../../Contracts/v1/merge-vectors.json); schema/fixture/vector validation passes. Production merge adoption is complete under S03/K02. See [C02 evidence](evidence/C02.md), [S03 evidence](evidence/S03.md), and [K02 evidence](evidence/K02.md).
- Depends: C01. Owner: integrator. Paths: `Contracts/v1/merge-*` and compatibility notes.
- Freeze deletion-wins-on-equal-time, book newer-modified choice, message-ID union and ordering. Specify canonical equal-time ties excluding device-local paths; preserve conflicting message/content payloads in recovery rather than discarding them. Define opaque-field merge behavior and repeat/no-op behavior.
- Add merge vectors for all permutations, duplicated operations, multi-provider propagation, clock skew limitations, deletion vs edit, and a same-ID/different-content collision. Mark which cases characterize legacy behavior and which require S03/K02 together.
- Done: expected outcomes are deterministic and shared, v1 remote-write race limitations are explicit. GCONTRACT; no production algorithm change in this task.

### S02 — Extract and inject the Apple sync pipeline

- Status: **done**. The canonical iOS suite passes 72/72, the macOS suite passes 1/1, and generic iOS build-for-testing passes. See [S02 evidence](evidence/S02.md).
- Depends: S01/A02. Owner: worker; integrator handles package wiring. Paths: coordinator/manifest/merge portions of `RemoteStorage.swift`, new Swift services/tests.
- Add repository, store factory, clock and scheduler seams; split orchestration from transport while preserving existing behavior. Keep foreground coalescing, rechecks after download/upload, missing-copy recovery, two-pass propagation and per-destination outcomes.
- Done: fake stores cover local edits/deletion during suspended transfers, missing/corrupt objects, unavailable local files, retry, no-op feedback and one failed destination. GSYNC/GAPPLE. Authentication/provider extraction is A07.

### K03 — Give Android sync an injected coordinator

- Status: **done**. Sync requests now share one injected coordinator and the fake-store lifecycle/trigger checks pass. See [K03 evidence](evidence/K03.md).
- Depends: K01/K05. Owner: worker. Paths: `K/sync/SyncEngine.kt`, provider lifecycle interface, sync trigger facade; settings UI wiring comes in K06.
- Inject store factory/repository/clock; serialize/coalesce runs, preserve cancellation, close SFTP/resources in finally, report each destination. Support manual/local-change/foreground/selection triggers through one API.
- Done: same applicable fake-store scenarios as S02, plus selection requests and cleanup on failure. The full Android unit/lint/debug-build check and seven focused coordinator tests pass. GSYNC/GANDROID. No wire-policy redesign.

### S03 / K02 — Apply the reviewed merge policy

- Status: **done at local policy/conformance gates**. Both clients implement the reviewed portable tie keys and recovery behavior, and both semantic test suites derive cases and expected outcomes from the shared vectors. Live provider and cross-device conflict validation remain separate follow-ups. See [S03 evidence](evidence/S03.md) and [K02 evidence](evidence/K02.md).
- Depends: C02 and S02 (S03), C02 and K03 (K02). Owner: one worker per language; integrator reviews both together. Paths: pure merge helpers and their engine call sites/tests only.
- Apply shared vectors to both implementations. Separate metadata choice from byte transfer, verify immutable content identity, recheck local revision after suspension, and keep recovery candidates. Do not silently resolve simultaneous remote manifest writes by claiming the two-pass algorithm is transactional.
- Done: GCONTRACT/GSYNC, permutation/idempotency vectors agree in both implementations, known new behavior documented, and both policy changes reviewed and integrated together. If conditional writes are added for an adapter, capability-specific tests and bounded retry are required; this is a separate child task. This milestone does not make v1 manifest writes transactional or verify live provider/device behavior.

## Apple services and platform work

### A02 — Extract durable Apple repositories

- Status: **done**. Injectable repositories/content store retain the existing facade and disk layout; canonical iOS/macOS projects were regenerated and the integrated iOS (64) and macOS (1) test schemes pass. See [A02 evidence](evidence/A02.md).
- Depends: A01/F02. Owner: worker. Paths: storage/conversation portions of `BookLibrary.swift`, new repository/content-store adapters and isolated tests.
- Move the SwiftUI history view to presentation first. Retain `BookLibrary` as a facade; extract current JSON persistence and safe managed files. Keep existing storage roots, preference keys, rollback, tombstone order and progress precision. Implement field mutations/revisions and surface durable failures.
- Done: import/delete failure injection, reload, pending-progress flush, missing-copy restoration and legacy decode pass. GDATA/GAPPLE. No new database or on-disk version in this task.

### A03 — Share asynchronous import orchestration

- Status: **complete at code and automated-test gates**. Picker/drop UI smoke with real OS document providers remains open; see [A03 evidence](evidence/A03.md).
- Depends: A02/F01. Owner: worker. Paths: `BookImportCoordinator`, Apple import service, Mac picker/drop call sites; share inbox adapter stays iOS-specific.
- Use one serialized async copy/metadata/commit flow for picker, Open In, inbox and Mac drop. Keep source access alive for the copy, acknowledge inbox after durable commit, open the first successful import, and return per-file failures.
- Done: existing import/inbox tests plus Mac mixed-success/cancel/retry; no main-thread file-provider wait. GDATA/GAPPLE and import UI smoke.

### A04 — Move EPUB preparation and share its policies

- Depends: A01/F01. Owner: integrator for move/build wiring; worker for behavior extraction. Paths: `EPUBPublication.swift`, Apple EPUB preparation/cache/resource/bridge assets, iOS/Mac host call sites.
- First move the existing loader from the iOS folder into the shared Apple target with its ZIP dependency and tests. Then create a child task to share JS/CSS, local resource access and navigation/footnote policy. Keep UIKit/AppKit hosts separate. Preserve recent iOS restoration/SVG/note fixes.
- Done: neither app references the other's sources; both open chapter/resource/fragment/note fixtures; cache invalidation and malformed/DRM/archive safety tests pass. GAPPLE/GREADER. A source move and bridge-policy change are separate reviews.

#### A04.a — Move the current EPUB loader into shared Apple sources

- Status: **done**. The loader now compiles from `Apps/Shared` in both generated apps; full current iOS and macOS test suites pass. See [A04.a evidence](evidence/A04.a.md).
- Depends: A01/F01. Owner: worker for source move, integrator for project regeneration and both-app checks. Paths: `Apps/iOS/CloudReader/EPUBPublication.swift` → `Apps/Shared/EPUBPublication.swift`; existing EPUB tests; A04.a evidence.
- Done: iOS and macOS both compile and pass current EPUB publication/web reader tests from the shared source. No bridge policy or visual changes.

#### A04.b — Share EPUB resource and navigation policy

- Status: **done with a refined boundary**. Shared resource and navigation decisions; keep UIKit/AppKit hosts and their materially different bridge scripts/styles native.
- Depends: A04.a. Preserve iOS restoration/SVG/note fixes and validate representative chapter/resource/fragment/note fixtures on both Apple targets.
- `A04.b.resources` is **done**: shared path, MIME, and HTML security policy; native `WKURLSchemeHandler` scheduling; focused containment/CSP tests. See [A04.b evidence](evidence/A04.b.md).
- `A04.b.navigation` is **done**: a Foundation policy classifies chapters and document/footnote links and carries fragments; iOS still validates and presents note sheets, while macOS keeps its existing internal-resource loading. JS/CSS remain native because viewport restoration, SVG, layout, and progress behavior differ. See [A04.b navigation evidence](evidence/A04.b.navigation.md).

### A05 — Share scalar pagination and reader preferences

- Status: **done**. Focused policy tests and the current package, iOS, and macOS suites pass. Native measurement and reader presentation remain platform-specific. See [A05 evidence](evidence/A05.md).
- Depends: A01/F02. Owner: worker. Paths: `ReaderAppearance.swift` value/math portions, Mac pagination/preference duplicates, shared tests.
- Move pure page/spread math and typed appearance values; keep native font measurement/UI at the edges. Preserve existing preference values. Port the iOS boundary correction to Mac through the shared helper.
- Done: round-trip matrix includes index 15/22 and 1/49, CJK/emoji/composed text, odd spreads and endpoints; native measured-fit tests still pass. GAPPLE/GREADER.

### A06 — Add durable Apple reader sessions

- Depends: A02/A05. Owner: worker. Paths: new reader session/load/progress controller and TXT/PDF reader integration, in separate platform child tasks.
- Resolve books by ID, load files asynchronously, show failed/retry state for invalid TXT, preserve precise local progress. Flush all debounce layers on dismissal/background/window close; do not reset PDF zoom on progress changes.
- Done: close/relaunch/rapid background persists last position, concurrent favorite/progress edits survive, unreadable TXT exits loading, PDF selection/zoom remain usable. GDATA/GREADER/GAPPLE.

### A07 — Separate Apple credentials and provider adapters

- Depends: S02. Owner: worker per adapter group; integrator owns manifest/dependency edits. Paths: auth/vault/provider portions of `RemoteStorage.swift`, Apple adapter directories.
- Child 1: credential vault/preferences and OAuth presentation/refresh. Child 2: Google/Dropbox/pCloud stores. Child 3: WebDAV/SFTP/folder stores. Preserve current scopes, redirect flows, SFTP identity checks and coordinated/security-scoped folder access. Share a registry; no UI in sync services.
- Done: deterministic HTTP/auth-refresh/error/cleanup tests plus unchanged configured-account loading. GAPPLE/GSYNC; live sign-in is recorded separately in Q02. Do not print credentials or change their identifiers.

### A08 — Share assistant application state on Apple

- Depends: A01/A02. Owner: worker. Paths: AI service/controller and iOS/Mac assistant integration in separate child tasks.
- Separate conversation values, remote transport, bounded context extraction, optional FoundationModels adapter and send/cancel/retry state. Use A01's injected credential/profile ports; the existing app wraps `SecureVault` until A07 moves it. Services must not depend on the Apple adapter target. Views render state/actions; App Intents use a scene-independent service container.
- Separate refinement child: new conversations default book context off even if selection/metadata exists; a restored conversation retains its saved choice. Current iOS/Mac reader-created chats can start with context on, so this is an intentional behavior change, not extraction parity.
- Done: three existing protocol tests, new/restored consent tests, cancellation/retry/history persistence, and an intent invocation without an open window; Apple model availability fails gracefully. GAI/GAPPLE. Real endpoint/on-device availability remains a separate device check.

### I01 — Harden the iOS reference and organize features

- Depends: A03/A04/A06/A08. Owner: worker with integrator review. Paths: iOS feature views, shared design tokens/components.
- Split library/reader/settings/assistant views one feature per child card. Keep current design and complete small-screen/wide-screen, share-import, unsupported-format and selected-passage flows. Capture reference screenshots and a behavior checklist for other platforms.
- Done: existing library/readers/favorites/history remain available, VoiceOver/large type/rotation/multitasking smoke passes, no missing selection or opening actions. GAPPLE/GREADER/GUI.

### M01 — Bring macOS to verified iOS parity

- Reader sub-batch **M01.reader** is complete at local runtime/UI gates under the user's 2026-10-21 Mac parity request: 62 runtime tests and 4 end-to-end UI tests pass. It covers the common shell, EPUB/TXT appearance and interaction repair, PDF viewport preservation, and FB2/CBZ/MOBI/AZW3/CBR readers. Shared preparation/contracts now live in `Apps/Shared`; platform availability stays in each shell. This does not close the remaining M01 library/assistant/multiple-window acceptance. See [reader evidence](evidence/M01-reader.md).
- Depends: A03/A04/A06/A08/I01 reference checklist. Owner: worker, split library/reader/assistant child cards. Paths: Mac feature views/adapters.
- Use shared services, latest book-ID state, async import, exact lifecycle flush, shared page math and EPUB note/fragment policy. Preserve the iOS visual family while retaining Mac menus, keyboard/pointer, settings and window behavior. Define and test secondary-window semantics.
- Done: TXT/PDF/EPUB close/reopen and note-return, drop/import, favorites, assistant context and multiple windows pass; selection and keyboard actions remain reachable. GAPPLE/GREADER/GUI.

## Android reliability and parity

### K04 — Preserve Android database upgrades

- Status: **done**. K04 was completed and reviewed before K01.a started because both tasks touch the database boundary.
- Depends: F03. Owner: worker. Paths: `K/data/CloudReaderDatabase.kt`, exported Room schema, migration tests/configuration.
- Export/freeze the current v1 schema without renaming the database; remove destructive fallback. The argument in `fallbackToDestructiveMigration(false)` does not disable destructive migration. Add a migration policy and tests before any future schema change.
- Done: existing v1 rows open unchanged, absent migrations fail safely, isolated upgrade tests retain books/chats/tombstones/local locations. GDATA/GANDROID. No schema bump needed merely to remove fallback/export schema.

### K05 — Make Android library mutations durable

- Status: **done**. The library/DAO fixes and durability instrumentation pass; the preserved legacy duplicate source is archived outside the compile tree. See [K05 evidence](evidence/K05.md).
- Depends: K04/K01. Owner: worker. Paths: `K/data/LibraryRepository.kt`, DAO mutation/transaction methods and targeted tests.
- Replace captured full-row updates with atomic field mutations; preserve unrelated favorite/progress changes. Persist tombstones before removing bytes, honor demo tombstones, check staged-file commit failure before saving a synced row, and recheck current state before applying downloaded metadata.
- Done: 12 JVM tests, lint, debug build, and 11 connected instrumentation tests pass, including concurrent update, demo-delete/relaunch, install failure, interrupted delete and latest-local-state cases. GDATA/GANDROID. No reader/UI refactor in this task.

### K06 — Give Android screens lifecycle-aware state

- Status: **done at local code and automated-test gates**. Library/navigation, settings, and assistant state are implemented. Device recreation and live-service checks remain explicitly unverified; see the child evidence files below.
- Depends: K05/K03. Owner: worker. Paths: `MainActivity`, navigation/composition root, feature ViewModels, settings bindings.
- Child cards for library/navigation, settings, then assistant shell. Expose immutable state/actions and selected IDs; screens stop accessing DAOs/vault/network directly. Wire manual sync and provider selection to the coordinator. Keep connection/selection/sync outcomes distinct.
- Done: recreation restores selection, settings changes trigger appropriate work, UI no longer owns transactions/network requests. GANDROID/GUI; use fakes for screen-state checks.

#### K06.library — Extract Android library/navigation screen state

- Status: **done**. Immutable screen state/actions and a lifecycle-aware ViewModel restore search/favorite filters; PDF selected-text routing resolves the book through the repository. Existing K06.a trigger wiring is retained. Activity recreation remains device-unverified; see [K06.library evidence](evidence/K06.library.md).

#### K06.settings — Extract Android settings state

- Status: **done**. Settings state/actions use an immutable lifecycle-aware ViewModel; existing preference keys/defaults, validation, provider selection, and sync triggers are preserved. See [K06.settings evidence](evidence/K06.settings.md).
- Depends: K06.library/K06.a. Owner: worker. Paths: settings portion of `AssistantSettingsScreen.kt`, a settings ViewModel/state file, focused tests, and scoped composition-root wiring if needed.
- Done: persisted preferences restore after recreation, changed provider selection keeps existing sync trigger behavior, and settings logic is testable without Compose or a live provider.

#### K06.assistant — Extract Android assistant screen state

- Status: **done at local code and automated-test gates**. Assistant state, consent persistence, retry, and cancellation of the actual OkHttp call are covered; live-provider and device lifecycle checks remain open. See [K06.assistant evidence](evidence/K06.assistant.md).
- Depends: K06.settings/K06.a. Owner: worker. Paths: assistant portion of `AssistantSettingsScreen.kt`, a ViewModel/state file, focused tests.
- Done: restore by conversation ID, request cancel/retry, explicit context consent, and history persistence pass lifecycle-focused tests; transport endpoints and protocol format remain unchanged.
- `K06.assistant.transport` is done: cancellation now calls OkHttp `Call.cancel()` and closes a late response without changing endpoint, payload, or protocol handling.

### K06.a — Route Android sync triggers through the coordinator

- Status: **done**. All four current trigger sources use the K03 API, with provider selection observed at application scope. See [K06.a evidence](evidence/K06.a.md).
- Depends: K03/K05. Owner: worker. Paths: `CloudReaderApp.kt`, `MainActivity.kt`, `LibraryScreen.kt`, and `AssistantSettingsScreen.kt`; targeted tests/evidence may be added.
- Route foreground, debounced local changes, provider-selection changes, and a visible manual action through `SyncEngine.request(trigger)`. Keep provider-selection observation alive across activity recreation and preserve per-destination outcome feedback. Do not refactor library, assistant, or settings state beyond what trigger routing requires.
- Done: no app trigger uses deprecated `sync()`; provider-selection flow skips its initial value and persists across Activity recreation by construction; manual and foreground requests remain coalesced. Focused flow/coordinator tests, Android unit/lint/build, and scoped whitespace checks pass. Activity recreation itself remains unverified on device.

### K07 — Make Android reader sessions survive lifecycle changes

- Status: **host and controller code complete at local gates; device lifecycle verification remains open**. EPUB remains K08.
- Depends: K05/K06.library/K06.a. Owner: worker per format child. Paths: reader controller plus TXT/PDF hosts in separate child cards.
- Flush pending TXT progress on close/stop, prefer valid local offsets on the same content, fall back to portable fraction. Preserve selection/context actions and hidden-control recovery. Async bounded text/context loading must not freeze a large book.
- Done: quick close, background, rotation/recreation and process relaunch restore progress; favorites do not get overwritten; invalid files show recovery actions. GANDROID/GREADER/GDATA.
- `K07.txt_pdf` adds TXT local-offset and PDF progress checkpoint behavior without changing EPUB, database schema, or sync behavior; see [K07.txt_pdf evidence](evidence/K07.txt_pdf.md).
- `K07.session` is **done at the controller and local-test gate**: TXT/PDF use a synchronized, ID-based checkpoint controller and progress-only writers; deterministic tests cover debounce, flush, serialization and preserved favorite state. See [K07.session evidence](evidence/K07.session.md). Device recreation/relaunch validation is still open.

### K08 — Finish Android EPUB behavior

- Depends: K07. Owner: worker. Paths: `EpubReaderActivity`, reader session/Readium host, EPUB instrumentation tests.
- Retain Readium. Restore the publication/fragment after recreation rather than ending the activity, add supported appearance controls and selection-to-AI, and preserve locator fallback. Split restoration and feature-controls into separate child cards.
- Done: rotate/recreate/relaunch remains in the book; typography/reflow/chapter navigation and selected-passage flow pass against the same sample books as iOS. GANDROID/GREADER/GAI.

### K09 — Match incoming-book import behavior

- Depends: K05/K06. Owner: worker. Paths: Android import handler/manifest, metadata extraction service, library import state.
- Route picker and OS Open/Share entry points through the same import service; handle content URIs/lifetimes, multiple inputs, duplicate names and partial failure. Preserve originals and show storage-only status for unsupported readers. Keep metadata extraction separate from durable copy.
- Done: instrumented external SEND/VIEW and picker flows import once, open first success, report failures, and retain source bytes. GANDROID/GDATA/GUI.

### K10 — Finish assistant lifecycle and consent behavior

- Status: **bounded-context child complete; end-to-end/device validation remains open**.
- Depends: K06. Owner: worker. Paths: assistant ViewModel/UI, AI transport/context boundary, AI tests.
- Restore chat by ID, define request cancel/retry, never restore a permanently busy flag without an active request, preserve three remote protocols and bounded context/history. Adopt the explicit A08 consent rule: new conversations start context off, restored chats retain their saved choice. A context preview explains saved-text sync.
- Keep local context extraction bounded while reading: do not load a whole TXT/PDF into memory before truncating to the prompt limit.
- Done: recreation, failed request, cancel/retry and history reopen pass; no request includes book text without consent. GAI/GANDROID/GUI.
- `K10.context` is **done**: TXT/PDF context files are read incrementally with the existing 18,000-character cap, without loading the complete file into memory. See [K10.context evidence](evidence/K10.context.md). Broader assistant/device checks remain open.

### K11 — Verify adaptive Android behavior

- Depends: K07/K08/K09/K10. Owner: worker. Paths: design tokens, shell/feature layout only; logic defects return to owning task.
- Test phone/tablet/foldable widths, hinge separation, keyboard/pointer, large text, dark/custom themes, TalkBack, minimum/current API. Arrange content around the hinge; do not paint over active controls. Match the iOS hierarchy without replacing native controls.
- Done: device matrix records tested dimensions/API/interaction and screenshots; reader actions remain reachable. GANDROID/GREADER/GUI. Untested devices are listed as unverified.

## Operations and acceptance

### O01 — Make book transfer efficient

- Depends: S03/K02/A07/K05. Owner: worker per platform child card. Paths: content/hash cache, provider transfer APIs, sync transfer call sites.
- Introduce streaming/file-backed transfer with limits/cancellation, cached verified hashes and file-change invalidation. Metadata-only changes must not read/upload the entire library again. Do not cache a hash as verified before install succeeds.
- Done: a large-book fixture uses bounded buffers, progress-only sync transfers metadata, changed/corrupt bytes are detected, failure retains the old copy. GSYNC/GDATA plus recorded memory/transfer evidence.

### O02 — Add credential-free export and safe restore

- Depends: A02/K05/C01. Owner: integrator specifies archive contract, workers implement separate Apple/Android cards. Paths: export schema/service, isolated restore, native entry points.
- Export bytes/portable metadata/chats/context/tombstones plus hashes; exclude keys/tokens/local connection secrets. Validate paths/hashes, stage restore, show restore summary and explicitly resolve duplicate/colliding IDs before committing. Preserve current library on failure.
- Done: export from each language restores into an isolated library in the other, malicious/corrupt archive fails safely, no credentials appear in archive, interrupted restore is recoverable. GDATA/GCONTRACT/GUI. Complete before X02 or any local-storage migration.

### Q01 — Add CI and consolidate documentation/resources

- Depends: F01/F02/F03; add contract jobs after C01 and package jobs after A01. Owner: integrator, split CI/resources/docs child cards. Paths: `.github/workflows`, `scripts`, README/platform guides, resource-copy checks, notices.
- Add path-aware gates: shared Apple changes test both apps; wire changes check Swift/Kotlin; Android changes unit/lint/build. Pin tool versions and check generation/dependency drift. Device/live-provider checks remain explicit separate jobs.
- Make product/build/architecture/status sources unambiguous. Keep one demo-book source with deterministic platform copies/checks. Update third-party notices for Android and shared Apple EPUB dependencies.
- Done: fresh checkout can run documented checks; failures are actionable; no personal secrets needed; platform feature claims include evidence level. Documentation cleanup preserves useful setup details.

### Q02 — Verify and integrate the current-platform milestone

- Depends: I01/M01/K11/S03/K02/O01/O02/Q01. Owner: integrator.
- Run affected checks, then two-device Apple↔Android and iOS↔Mac round trips: import bytes, offline progress/favorite edits, deletion, saved chat/context, reconnect, partial-provider failure/retry, app update/relaunch. Check explicit v1 concurrency limitations instead of claiming lossless simultaneous manifest writes.
- Verify selected providers with dedicated test libraries/accounts, token refresh, SFTP identity handling and folder access. Record unavailable tests, signing/install limitations and platform-specific AI capabilities separately. Do not use a personal library as a destructive test fixture.
- Done: no new failure against the baseline, no data loss in defined supported scenarios, all acceptance evidence reviewed, release/package checks match the intended delivery channel. GRELEASE. Repair caused defects before any dependent milestone.

## Windows / Linux expansion

### D01 — Prove the proposed desktop stack

- Depends: Q02. Owner: integrator design review plus bounded prototype worker. Paths: isolated desktop prototype and decision record; existing apps unchanged.
- Prove Kotlin/JVM Compose Desktop on Windows and Linux with TXT/PDF/EPUB load, selection, resume, keyboard/screen-reader access, file picker/drop, durable local storage and OS credential storage. Choose maintained reader engines after checking license/package/architecture constraints. AndroidX PDF and Android Readium are not assumed to run on desktop.
- Done: actual OS evidence and an ADR ratify or revise the stack. Include package size/startup, engine limitations and JVM/native dependencies. If a required engine or accessible integration fails, revise this decision before D02; do not disguise a placeholder reader as delivered.

### D02 — Extract reusable Kotlin domain/contract services

- Depends: D01/K02/K03/K06. Owner: integrator for Gradle graph; worker for pure code move. Paths: new `Packages/CloudReaderKotlin`, Android adapters/call sites, desktop dependencies.
- Extract Android-free domain/wire/merge/transport-neutral services to a JVM library. Keep Room/DataStore/SAF/Keystore/Readium hosts in Android. Do not copy entities into desktop or introduce a Swift bridge.
- Done: desktop and Android consume one Kotlin implementation; GCONTRACT/GANDROID and desktop unit checks pass; no behavior change to installed Android libraries.

### D03 — Deliver local desktop reading in vertical slices

- Depends: D02. Owner: worker per slice. Paths: future `Apps/Desktop` local repository/library/native integration/readers.
- D03.a library/import/TXT/resume; D03.b PDF/selection/resume; D03.c EPUB/chapter/appearance/selection; D03.d accessible library/favorites/history scaffolding and restore. Freeze store/reader interfaces before parallel format work.
- Done per slice: installed app imports a copy, reads offline, closes/relaunches at saved location and exposes failures. Windows/Linux each run GREADER/GUI; a Mac-hosted desktop preview is insufficient.

### D04 — Add desktop sync and assistant

- Depends: D03/O02. Owner: worker per adapter/feature child card. Paths: desktop provider adapters/coordinator integration, secure vault, assistant and export/restore.
- Start with a local synced folder and WebDAV against shared fixtures; add remaining current provider adapters after authenticated test flows are proven. Reuse Kotlin contract/merge/AI protocol logic, add OS OAuth callbacks/credential adapters, and preserve consent/history semantics.
- Done: desktop↔existing-client round trip, failure/retry, credential isolation, selected-passage AI, export/restore pass. GCONTRACT/GSYNC/GAI/GUI on each OS. Unsupported provider integrations stay visibly unavailable.

### D05 — Package and verify Windows

- Depends: D04. Owner: worker on Windows with integrator release review. Paths: Windows integration/installer/CI/docs.
- File associations, open/drop, credential storage, update preserving library, keyboard/UI scaling/screen-reader checks, installer/signing behavior for the selected channel. Set the supported OS/CPU matrix in the ADR before release.
- Done: Windows runner builds installer; install/update/uninstall-preserve-data scenarios and GRELEASE pass on Windows. Keep signing/publishing separate from local packaging authorization.

### D06 — Package and verify Linux

- Depends: D04. Owner: worker on Linux with integrator release review. Paths: Linux integration/package/CI/docs.
- Desktop entry/MIME handling, file dialogs, credential service availability and explicit unavailable state, scaling/keyboard/accessibility, package/runtime dependencies, update preserving library. Ratify supported distributions/session/CPU combinations before release.
- Done: Linux runner builds chosen packages; install/update/resume and GRELEASE pass on declared environments. Never fall back to plaintext credentials when a secret service is absent.

## Later protocol and feature work

### X01 — Design portable v2 and its compatibility rollout

- Depends: Q02/O02. Owner: integrator. Paths: versioned schema/fixtures, migration/ADR documents only.
- Define library/device identity, content-addressed objects, exact locator contracts, per-entity causal changes/conflicts, annotations, retained deletions, immutable operations/rebuildable snapshots, provider limits, interrupted migration and rollback. Specify the separate v2 namespace and how each upgraded device joins it.
- Done: migration and mixed-client scenarios have expected outputs; no old v1 writer can overwrite the new namespace; GC/compaction cannot resurrect offline deletes or drop unseen operations. Review before writing production migration code.

### X02 — Implement v2 in reviewed vertical slices

- Depends: X01 and restored-backup proof from O02. Owner: integrator defines new child tasks; one worker per codec/engine/adapter/UI slice.
- First dual-read isolated fixtures, then staging migration, device/library join, causal merge, format locators, conflict choice UI, annotations, and finally rollout. Gate all switches. Do not replace `manifest.json` in place or turn on speculative bidirectional v1/v2 mirroring.
- Done: cross-language fixtures, fault/restart/rollback tests and two-device migration rehearsal pass before enabling v2 for a live library.

Background transfers, in-book bookmarks/highlights, full-text search and additional direct cloud providers receive new bounded cards after the stable-current-platform milestone. The separately requested iOS reader repair and format work is tracked below; its device gate remains distinct from the broader architecture cleanup.

## iOS reader repair and format expansion

This work follows the current iOS reader as the visual reference and uses one SwiftUI shell with native format adapters. Keep status device evidence separate from simulator results. The current working tree is intentionally dirty; preserve unrelated files and the historical duplicate project/source artifacts described in `AGENTS.md`.

| Card | Status | Boundary and completion gate |
| --- | --- | --- |
| IOS-R00 | [Complete](evidence/IOS-R00.md) | Freeze `ReaderContracts.swift`; extract TXT, selectable-text and PDF adapters. The integrator owns project generation and wiring. |
| IOS-R01 | [Complete at simulator gate](evidence/IOS-R01.md) | One shell-owned visibility state, common controls, capability-aware appearance and page/chapter status. Physical device behavior is included in R04. |
| IOS-R02 | [Needs wide-device verification](evidence/IOS-R02.md) | EPUB viewport normalization, styling, one/two-page snapped navigation and chapter-boundary swipes. The current narrow simulator cannot exercise the 700-point spread mode. |
| IOS-R03 | [Complete at simulator gate](evidence/IOS-R03.md) | Preserve TXT source-text location and PDF page, selection, destination and zoom while chrome/layout changes. Physical device behavior is included in R04. |
| IOS-R04 | [Active; physical review deferred](evidence/IOS-R04.md) | Integrate, inspect screenshots, run the iPhone Air landscape spread checks and verify installed-update retention. Do not start subsequent format expansion until this gate passes. |
| IOS-F01 (FB2) | [Complete at unit/simulator gates](evidence/IOS-F01.md) | Namespace-aware SAX-style XML conversion to the shared reflow adapter; preserve inline order, notes/resources, source bytes and safe staging. |
| IOS-F02 (CBZ) | [Active; wide-device verification pending](evidence/IOS-F02.md) | Ordered image publication and native comic adapter; enforce archive/image limits, resume/swipe, zoom/pan and odd final spreads. |
| IOS-F03 (MOBI/AZW3) | [Preparation verified; availability gated](evidence/IOS-F03.md) | Offline DRM-free Foliate-js conversion with the pinned revision and fflate version below; first prove local resource/link export and iPhone performance. |
| IOS-F04 (CBR) | [Preparation verified; availability gated](evidence/IOS-F04.md) | Reuse the comic adapter; vendor the pinned Unrar.swift source only after RAR4/RAR5 and solid-archive gates pass. |

### IOS-R00 through IOS-R04 — Repair the existing readers

- IOS-R00 freezes `ReaderCapabilities`, `ReaderLayoutMetrics`, `ReaderNavigationState`, unique `ReaderNavigationRequest`, `PreparedPublication`, and the content-tap callback before worker changes. Contracts and common controls moved to `Apps/Shared` during M01.reader; extracted iOS native adapters remain in `NativeBookReaders.swift`. The integrator owns `CloudReader.xcodegen.yml` and generated-project wiring.
- IOS-R01 owns `BookReaderView.swift`, `ReaderAppearance.swift` and `ReaderChromeControls.swift`. Opening starts with controls visible. A content tap hides/restores navigation, AI, favorite, appearance, bottom tabs and status bar; hidden controls release layout space and accessibility exposure. Preserve existing preference keys and native selection/link/zoom behavior.
- IOS-R02 owns `EPUBBookReader.swift`, its iOS bridge/style assets and EPUB web tests. Normalize device viewport before pagination; use a snapped horizontal scroll view with a visible-text anchor, actual page/spread state, chapter-boundary turns and stale-callback rejection. Normalize publisher prose while preserving semantic structure, resources, SVG and footnotes.
- IOS-R03 owns the extracted TXT/PDF adapters and native text view. TXT restores by source-text offset through repagination. PDF keeps its page/destination/selection/zoom when chrome changes. Do not add PDFKit page-controller behavior in this card.
- IOS-R04 owns integration, isolated UI tests and device review. Verify iPhone Air portrait/landscape and a wide target, actual swipes at the spread breakpoint, chrome visibility, matching EPUB/TXT appearance, selection/AI, rotation/background/reopen, and existing-library retention. The device must be unlocked for XCUITest; a successful install is not device-test evidence.

Current local evidence: XcodeGen regeneration, Swift parsing and `git diff --check` pass. The 2026-10-21 iPhone Duo simulator suite passed 136 tests with 3 wide UI checks skipped because their measured reader widths were 382–466 points; the PDF page-preservation test also passes without runtime warnings. A generic iOS device build and install on the paired iPhone Air succeeded. Its landscape XCUITest attempt stopped at Xcode preflight with “Unlock J03.AIR to Continue”; therefore IOS-R04 and actual wide-spread interaction remain open. The user deferred physical review; no repeated unlock request is required. MOBI/AZW3 and CBR preparation now passes local fixture/build checks, but the shell still withholds those readers pending the remaining gates. See [`IOS-R04.md`](evidence/IOS-R04.md) for exact limits.

### IOS-F01 through IOS-F04 — Add iOS formats after R04

- IOS-F01 uses a namespace-aware XML event converter and the repaired reflow renderer. Preserve mixed text order, headings, embedded images, notes/backlinks, malformed-input handling, cancellation and original FB2 bytes. Enable only on iOS after tests pass.
- IOS-F02 uses ZIPFoundation and the native comic reader. Natural numeric ordering, archive path/encryption/split-volume checks, 10,000-entry, 64 MiB-per-image and 1 GiB-unpacked limits, ImageIO downsampling, a 64 MiB decoded cache, actual swipes, zoom/pan, resume and an odd last spread are required. Do not enable CBR as part of CBZ.
- IOS-F03 vendors only Foliate-js revision [`78914aef4466eb960965702401634c2cb348e9b1`](https://github.com/johnfactotum/foliate-js/commit/78914aef4466eb960965702401634c2cb348e9b1) and fflate 0.8.2. Convert offline in an isolated context and export validated local chapters/resources into the existing renderer. Reject DRM before decoding; do not enable until DRM-free MOBI6, KF8/AZW3, combo, compressed resources, links, corruption and iPhone performance pass. KFX, print replica, dictionaries and fixed layout remain unsupported.
- IOS-F04 vendors [Unrar.swift 0.5.4](https://github.com/mtgto/Unrar.swift/releases/tag/0.5.4) at commit `7216007a38ac122dbdeae26cfdaf7f10775c868f` with its MIT/UnRAR notices. Add one sequential streaming adapter supporting solid archives only after simulator/device builds and RAR4/RAR5 solid/nonsolid fixtures pass. Reject unsafe paths, links, encryption and split volumes; cap the dictionary at 64 MiB.
- All preparation runs off the main thread, supports cancellation, writes disposable cache output through staging plus an atomic completion marker, and leaves imported originals and v1 sync records unchanged. Feature readiness is iOS-specific; do not flip shared `BookFormat.hasNativeReader` for formats unavailable on macOS.

## Parallel dispatch policy

After F00, F01 and F03 may run independently; F02 follows F01. C01/C02 contract design can be reviewed independently, but cross-language conformance is not verified until both language suites consume the same fixtures and vectors. After A01 and contract freeze, run an Apple lane, an Android lane and a test/contract lane with disjoint paths. The integrator serializes package/project/schema changes.

Do not concurrently dispatch A02 and S02 against `BookLibrary`/`RemoteStorage`; obey their dependency. Do not dispatch S02 and A07 against the unsplit provider file together. UI tasks wait for their service APIs. Desktop starts after Q02. A worker owns one active card, not an entire platform backlog.

Evidence/status updates belong in `docs/engineering/evidence/<task-id>.md` once execution starts: pending → active → review → done, or needs-input with the exact missing requirement. The integrator updates the milestone status only after checking the patch and evidence. Reopen the responsible card for a regression; dependent work does not proceed through a failed shared boundary.
