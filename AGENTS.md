# CloudReader coding instructions

Use the user's current request to determine scope. The engineering backlog is a plan, not authorization to execute every task whenever this repository is opened.

## Start with the assigned task

- Engineering entry point: `docs/engineering/README.md`.
- Architecture and boundaries: `docs/engineering/ARCHITECTURE.md`.
- Task dependencies/acceptance: `docs/engineering/IMPLEMENTATION_PLAN.md`.
- Handoffs/checks/repair: `docs/engineering/AGENT_WORKFLOW.md`.
- Product requirements: `docs/PROJECT_SPEC.md`.
- Read the relevant card and files; avoid loading every plan/source file for a small task.

## Preserve the existing application

- Current iOS is the product/visual reference. Keep macOS in the same visual family, with native desktop interactions. Android remains native Kotlin/Compose.
- Preserve uncommitted and untracked work. The planning baseline includes active EPUB, share extension, import and test files. A fresh checkout of committed `main` may omit them. Complete F00 before parallel implementation checkouts.
- Do not delete unexplained duplicate projects/plists or reset unrelated changes. Compare and preserve unique contents before cleanup.
- Retain original imported files, installed library data, preference keys, credential identifiers, SDK minimums and dependency resolutions unless the selected task explicitly changes them.
- Initial extraction keeps schema v1: Foundation-reference-date numeric timestamps, UUID/object naming, favorites, chats and tombstones. Keep local paths/credentials out of portable models. Schema changes and migration switches belong to the integration owner.
- `isBookmarked` means a library favorite, not an in-book annotation.

## Ownership and checks

- Work on one bounded card and an explicit path list. Freeze shared interfaces before parallel feature work. A single integration owner handles schemas/models, package manifests, XcodeGen/project files, dependency locks, migrations and integration in each concurrent batch.
- XcodeGen YAML is the canonical Apple build configuration. Update the spec and regenerate together; a lasting project-only edit is insufficient. F01 repaired the Mac EPUB source/dependency wiring. Preserve the excluded historical `AppleSyncPipeline 2.swift` and `BookImportCoordinator 2.swift` copies; do not compile them alongside the current shared implementations.
- Shared Apple changes must check iOS and macOS. Wire/merge changes must use the same shared Swift/Kotlin fixtures after C01. Platform UI must not implement its own sync policy.
- Keep core values/merge logic free of SwiftUI/UIKit/AppKit/PDFKit/Room/Compose. Inject OS/storage/network adapters. Keep native reader hosts at platform boundaries.
- Tests use temporary storage and isolated preferences/databases. Existing Apple tests include real-store access (F02); Android's import instrumentation test deletes the target app's managed Books directory despite using an in-memory database (F03). Isolate both before running them against existing installations. Do not test destructive/recovery cases against the user's library or personal sync destination.
- Run checks appropriate to the change. Report actual results and distinguish source inspection, automated verification and live/device verification. Do not claim planned scripts/targets/features already exist.
- Repair errors caused by the assigned change and rerun affected checks. Escalate cross-boundary or repeated failures to the coordinating agent with a reproduction; do not weaken tests or leave dependent work on a broken integration.

No publication, release, whole-project rewrite, new backend, or new desktop framework is required by these instructions. Follow the current user task and the selected card.
