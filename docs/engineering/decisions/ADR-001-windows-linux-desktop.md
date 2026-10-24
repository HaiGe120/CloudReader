# ADR-001: Unified Windows/Linux desktop client

- **Status:** Proposed; implementation begins with the D01 feasibility slice.
- **Date:** 2026-10-24
- **Owners:** CloudReader integration owner

## Decision

CloudReader will use one shared Kotlin/JVM Compose Desktop application for Windows and Linux. Android, iOS, and macOS remain native applications. Android-independent domain values, schema codecs, deterministic merge policy, assistant protocol helpers, and transport-neutral service interfaces will be extracted into `Packages/CloudReaderKotlin` and consumed by Android and desktop.

Desktop integrations remain behind ports. Windows and Linux adapters own file dialogs and drop handling, managed storage, credential access, browser/OAuth callbacks, accessibility integration, and packaging. Android Room, DataStore, Storage Access Framework, Keystore, Readium, and Android PDF hosts stay Android-only.

Compose Desktop is a gated default. D01 must prove TXT, PDF, and EPUB loading, selection, resume, durable local storage, keyboard navigation, screen-reader access, file picker/drop, and credential behavior on actual Windows and Debian 12 environments. If the reader or accessibility gate fails, the shared Kotlin core remains valid and the desktop UI/reader host may be replaced without rewriting the core.

## Delivery shape

1. **D01:** isolated desktop feasibility prototype and engine/license report.
2. **D02:** pure Kotlin/JVM extraction with shared contract and merge fixtures.
3. **D03:** local reading slices: TXT, PDF, EPUB, then FB2/CBZ/CBR/MOBI/AZW3 where maintained engines and licenses permit.
4. **D04:** local-folder and WebDAV sync, then additional providers and assistant integration.
5. **D05/D06:** Windows and Debian 12 packaging, update preservation, file associations, scaling, and accessibility checks.

Source remains buildable for other Linux distributions. GitHub Actions is the delivery system, with Windows and Debian 12 runners producing reproducible artifacts and running the desktop checks.

## Credential policy

The desktop client prefers the Windows Credential Manager and Linux Secret Service/KWallet. If no supported Linux secret service is available, the user may explicitly opt in to a plaintext local fallback for provider and AI credentials. The fallback is disabled by default, is clearly disclosed in Settings, is protected by per-user file permissions/ACLs, and is never included in sync or export data. This is an intentional change from the previous secure-store-only proposal and must be called out in release documentation.

## Consequences

- Reader-engine and accessibility support are the first technical risks and cannot be inferred from Android behavior.
- Desktop packaging is validated on the target operating systems; a Mac-hosted preview is insufficient.
- The Kotlin extraction reduces contract and merge duplication without forcing a mobile UI rewrite.
- Supporting all current reader formats is staged; unsupported formats remain importable and visibly unavailable until an engine is validated.
