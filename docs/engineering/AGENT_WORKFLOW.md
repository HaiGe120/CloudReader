# Coding-agent workflow

This workflow supports small, bounded coding assignments. The coordinating agent owns architecture, compatibility, integration, and repairs that exceed a worker's scope. The user chooses the actual model at dispatch time; model nicknames are not assumed to be valid tool identifiers.

## Before dispatch

Complete F00 first: the working tree contains valuable uncommitted and untracked implementation. Worktrees created from the current committed `main` alone will omit it. Reuse the preserved baseline or an integration checkpoint that includes the required work. Use `codex/` branch names when a branch is needed; no automatic publication is part of this plan.

The coordinator chooses one ready card from [the plan](IMPLEMENTATION_PLAN.md), freezes its consumed interfaces, and lists actual owned paths. Split a parent card that spans unrelated behaviors or more than about five production files. File-count guidance is a sizing aid; a source move can reasonably touch more call sites, but still needs one purpose and a single owner for project wiring.

Each worker reads the root `AGENTS.md`, its assigned card, the relevant architecture section/contract fixtures, then its specific source/tests. Do not load the entire backlog/history into every worker or repeatedly ask it to rediscover the architecture. Supply small excerpts and exact paths. A worker can delegate only within its owned, nonoverlapping scope.

Recommended handoff template:

```text
Task: <ID / child ID and one concrete outcome>
Baseline: <checkpoint or preserved tree; known failures relevant to this task>
Read: <card, contract section, 2–5 source/test paths>
Own: <explicit paths; new files permitted here>
Consume: <interface names/signatures/version, immutable for this task>
Change: <one extraction or one behavior fix>
Preserve: <wire keys, local storage/preferences, UI behavior, source originals>
Acceptance: <2–4 observable examples including a failure case>
Checks: <gate IDs and actual commands for this checkout/device>
Exclude: <related changes that belong to other cards>
Return: changed paths, acceptance evidence, checks/results, remaining limits
```

For example, A05 gets the page/spread helpers, current iOS boundary tests, Mac duplicate, and preference values. It does not get authority to redesign the reader, add a portable schema, or change the EPUB engine.

## Concurrency and integration

One owner changes each production file per batch. Shared model/schema changes, package manifests, generated project configuration, dependency locks, migration switches and release integration are serialized by the coordinator. Other workers can propose a required manifest change for the coordinator instead of editing the same file.

Parallel work is useful after interfaces stabilize: one worker on Apple behavior, one on Android behavior, one on fixtures/test tooling. Readers can be split by format only after the session interface is stable. Do not give two workers `RemoteStorage.swift` simultaneously, and do not run competing project generators in the same checkout.

Workers keep a narrow diff, run the affected gate, and report what actually ran. The coordinator reviews the result against the assigned card, integrates one patch, then runs the checks affected by integration. An Apple shared change always checks both apps. A wire-policy change checks all current clients. Passing a unit test does not establish live provider/device behavior.

## Validation gates

| Gate | Required evidence |
| --- | --- |
| G0 | Recoverable baseline includes functional untracked work; tool/environment inventory; current vs generated-project failures recorded |
| GAPPLE | Stable project generation; iOS simulator build/tests incl. extension; Mac build/tests; shared package tests once created; no unintended resolution/signing drift |
| GANDROID | JVM unit tests, lint, debug build; targeted instrumentation for changed file/database/reader/platform behavior |
| GCONTRACT | Same on-disk fixtures consumed by Swift/Kotlin; semantic outputs/defaults/unknowns match; version and path/hash failures handled. C01 validates schema and fixture dispositions with `uv run --with-requirements scripts/contract-validation-requirements.txt python scripts/validate-contract-v1.py`; adapter adoption is covered by K01 and S01/S01.c. Combined compatibility remains the milestone-1 exit gate |
| GDATA | Isolated stores; legacy/reload/failure/restart behavior; byte installation/tombstone ordering; no real-library/settings writes |
| GSYNC | Fake stores exercise permutations, two-provider propagation, idempotency, partial failure/retry, corrupt/missing bytes, local changes while awaiting I/O; remote write guarantees accurately limited |
| GREADER | TXT/PDF/EPUB import/open/close/relaunch/resume; selection, theme/reflow and large/invalid content; platform recreation/window/background events |
| GAI | Three remote protocol payload/result fixtures; opt-in bounded context; key exclusion; cancel/retry/history; capability availability |
| GUI | iOS reference parity, compact/large windows, accessible labels/focus/type scaling, platform keyboard/pointer and screen-reader checks |
| GRELEASE | Cross-platform two-device round trip; dedicated-provider auth refresh; installed update retains data; packaging/signing/channel evidence and outstanding live checks |

Use existing tests before inventing broad new suites. Add regression coverage for a real bug, state transition, protocol boundary, storage failure or integration risk. Pure folder/document moves need build/link checks, not tests that assert file names. New fixtures must be independent enough to detect a faulty implementation rather than mirror its output.

Baseline commands below are starting points, not evidence that they have already passed. Run from the repository root; discover a valid simulator/device and set task-specific destination values. F00/F02 must isolate Apple tests and F03 must isolate Android test files/database before commands that could affect the default application store. Logs and build products belong outside source control.

```sh
# Build current Apple projects; compare with generated staging copies in F01.
xcodebuild -project Apps/iOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath <local path> CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Apps/macOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination 'platform=macOS' \
  -derivedDataPath <local path> CODE_SIGNING_ALLOWED=NO build

# Choose a simulator from installed devices; use a per-task output directory
# if multiple workers are running. Do not run legacy real-store tests unchanged.
xcodebuild -project Apps/iOS/CloudReader.xcodeproj -scheme CloudReader \
  -destination "platform=iOS Simulator,id=$CLOUDREADER_IOS_SIMULATOR_UDID" \
  -derivedDataPath <local path> CODE_SIGNING_ALLOWED=NO test

# After A01 introduces the package; choose the appropriate host/test target.
swift test --package-path Packages/CloudReaderKit

# From the repository root: unit tests, lint, and debug build.
./scripts/check-android.sh
# With exactly one explicitly selected online emulator/device:
ANDROID_SERIAL=emulator-5554 ./scripts/check-android-instrumented.sh
```

F01 adds stable generation/check tooling, F03 adds Android tooling, Q01 combines them in CI. Package/Mac test commands become applicable only when those targets exist. Tests involving UIKit/WebKit/PDFKit still run with the corresponding Apple host; a host-only package test does not replace iOS integration tests. An environment failure is reported with the failed prerequisite and does not become a passing or skipped-by-default check.

## Failure and repair ownership

Workers may repair errors they introduce inside their owned scope. They reproduce the failure, add a meaningful regression case where appropriate, fix the cause, rerun the failed check and affected neighboring checks, then return evidence. A compiling patch with failing behavior is not done.

After two unsuccessful focused attempts, or immediately when a fix requires changing shared contracts/migrations/another worker's files, send the coordinator the minimal reproduction, expected/actual behavior, diff, failing check and evidence. This is an escalation to integration, not a request for the user to debug the code. The coordinator diagnoses and repairs the integration, narrows/reassigns the task, or reverts only the task's own changes. Never reset unrelated user work. Do not launch dependent tasks through a broken boundary.

Separate baseline defects from regressions using F00 evidence. A nearby pre-existing bug can get a new bounded repair card; it does not justify an unreviewed rewrite. Restore the last safe integration checkpoint if necessary and preserve failed-patch evidence. No worker can waive data preservation, silently change schema/version, or replace failing tests with weaker assertions to obtain a green result.

Each completed task records a short evidence file in `docs/engineering/evidence/<ID>.md` containing baseline/checkpoint, paths changed, acceptance examples, commands/device and results, remaining unverified behavior, and any follow-up repair IDs. Status starts pending, becomes active, then review, and reaches done only after coordinator verification. Do not copy full tool logs or private credentials into the evidence file.

The coordinator reports milestone outcomes to the user in plain language: behavior improved, checks passed, material remaining limits, and repairs performed. Detailed evidence stays in the task files so future workers need only the relevant context.
