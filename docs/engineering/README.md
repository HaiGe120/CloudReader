# CloudReader engineering plan

Prepared 2026-10-20 from the current working tree. This is the implementation map and current integration handoff. F00/F01/F02/F03, C01/C02, K04, A01/A02/A03/A04.a/A04.b/A05, K01, S01/S01.c/S02/S03, K02/K03/K05, Android K06.a/library/settings/assistant, K07 controller, and K10.context are complete at their documented local gates. Both merge-policy test suites consume shared vector inputs and expected outcomes. Live provider, cross-device, import UI, and reader lifecycle smoke checks remain open. The earlier foundation gates passed iOS 89 tests, macOS 2, Android 51 unit tests plus lint/build, and 15 connected emulator tests. The 2026-10-21 reader batch now passes iOS 132 unit tests and macOS 62 runtime plus 4 end-to-end UI tests; see [Mac reader evidence](evidence/M01-reader.md) and the iOS reader cards for scope and device limits. Next are A06/A07/A08, Android K07 device validation/K08/K09/K10 end-to-end, then remaining platform parity work; other modules stay planned until their task evidence says otherwise.

**Decision:** keep the existing native iOS, macOS, and Android apps. Use iOS as the product and visual reference. Extract shared behavior within each language, and make a tested data contract the boundary between languages. Stabilize the existing apps before expanding to Windows and Linux.

Read only what the current task needs:

| Document | Purpose |
| --- | --- |
| [Current state](CURRENT_STATE.md) | Source-backed inventory, existing defects, and verification limits |
| [Architecture](ARCHITECTURE.md) | Module boundaries, data ownership, interfaces, and migration decisions |
| [Implementation plan](IMPLEMENTATION_PLAN.md) | Ordered work packages, dependencies, allowed scope, acceptance checks |
| [Agent workflow](AGENT_WORKFLOW.md) | Small-model handoffs, integration ownership, validation, and repair |
| [Product specification](../PROJECT_SPEC.md) | Existing product requirements and schema-v1 description |
| [Repository instructions](../../AGENTS.md) | Short rules for future coding agents |

The foundation and contract baseline is in place. Continue with bounded service extraction and platform parity work. Current EPUB/share-import work and other working-tree changes are active implementation and must be preserved; a worktree from committed `main` will not contain them.

The implementation plan and evidence files track both code and documentation changes. Each completed card records its owned paths, acceptance evidence, commands, and limits. Keep the user informed of regressions and repair them before starting dependent cards; never reset, replace, or discard unrelated working-tree changes.

Document authority: `PROJECT_SPEC.md` owns product intent; `ARCHITECTURE.md` owns the proposed code structure; `IMPLEMENTATION_PLAN.md` owns execution order/status; `Contracts/` owns the v1 wire specification and fixtures. When documents disagree, compare them with source and resolve the disagreement in the relevant task; a planned capability is never evidence that it already ships.
