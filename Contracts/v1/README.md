# CloudReader portable sync contract, v1 (reviewed baseline)

This directory describes the manifest currently used by iOS, macOS, and Android. It is an initial interoperability target; fixture adoption and preservation evidence are tracked separately from normative rules. As of 2026-10-20, Android and Apple consume all 13 fixture pairs. Apple remote preflight validates a complete manifest before sync side effects, while local Codable decoding remains permissive for legacy persistence. Platform behavior below is characterized from `Packages/CloudReaderKit/Sources/CloudReaderCore/`, `Apps/Shared/RemoteStorage.swift`, `BookLibrary.swift`, and Android `sync/SyncCodec.kt` plus `data/Models.kt`.

## Envelope and encoding

The remote index is `manifest.json`. Its root fields are `schemaVersion`, `updatedAt`, `books`, `deletions`, `conversations`, and `conversationDeletions`. Version 1 is the only supported version. A manifest's book entries are `{ "book": <Book>, "sha256": <digest> }`; book bytes are separate objects named `book-<UUID>.<format>`. SHA-256 is computed over the exact book bytes and emitted as 64 lowercase hexadecimal characters. Swift emits UUIDs in its canonical hyphenated spelling (normally uppercase); Android canonicalizes to uppercase. UUID identity is case-insensitive; consumers should compare parsed UUID values, not raw spelling.

All timestamps are JSON numbers in seconds from 2001-01-01T00:00:00Z (Foundation's reference date), not Unix seconds or ISO-8601 strings. Fractional seconds are valid and must be retained. JSON numbers must be finite. Progress is a finite numeric fraction in the inclusive range [0,1]. Android rejects out-of-range values in its wire codec; Apple remote preflight rejects them before sync side effects while local decoding remains backward-compatible. JSON has no standard non-finite numeric literals; adapters must also reject numeric tokens that overflow their finite numeric representation.

## Records

Book fields: `id`, `title`, `author?`, `briefDescription?`, `fileName`, `format`, `addedAt`, `lastOpenedAt?`, `progress?`, `isBookmarked?`, `modifiedAt?`. Android's legacy defaults are progress 0, bookmark false, and modifiedAt = lastOpenedAt or addedAt. Swift defaults those same values when decoding absent fields. Author/description/lastOpenedAt are optional and omitted when absent. The canonical v1 producer spelling for the formats currently enumerated by both platforms is lowercase: `epub`, `pdf`, `txt`, `mobi`, `azw3`, `fb2`, `cbz`, `cbr`. The schema lists only these lowercase values. Android lowercases a received format before lookup; Swift decodes its raw lowercase enum value, so uppercase acceptance is not a cross-platform compatibility guarantee and must not be emitted by producers.

Book tombstones contain `bookID` and `deletedAt`. Conversation tombstones contain `conversationID` and `deletedAt`.

Conversation fields: `id`, `title`, `messages`, optional `bookID`, `bookTitle`, `bookDescription`, `selectedText`, `bookContext`, `contextDescription`, `includeBookContext`, `createdAt`, `modifiedAt`. A message has `id`, `role`, `text`, `createdAt`; the v1 roles emitted by the current app are `user` and `assistant`. Swift retains any other role string as `.unknown(rawValue)` and encodes it unchanged; Android's `ChatMessage.role` is an unrestricted string. Android defaults absent messages to [], absent conversation createdAt to the earliest message time or 0, modifiedAt to createdAt, and includeBookContext to false. Swift's required conversation/message properties do not have equivalent decode defaults. Saved book context is portable user data; provider credentials, API keys, local paths, and provider configuration are not manifest fields.

## Observed behavior vs contract expectations

Observed today: Android rejects unknown schema versions, unknown book formats, and filenames outside `[A-Za-z0-9._-]{1,160}` or containing `..`; it lowercases format, uppercases UUID strings, validates an incoming digest as lowercase hex before download, and rejects progress outside `[0,1]`. Swift rejects non-v1 manifests, uses its known book enum, preserves unknown fields and unknown role strings through Codable/local persistence, and validates remote digests and names before provider content access. Its remote filename allowlist matches Android's character set and length. Android and Swift retain unknown JSON members at root, book, conversation, message, tombstone, and book-entry levels. Both adapters consume all 13 fixtures; Apple remote preflight rejects invalid semantic fixture cases before sync side effects.

Normative safety expectation for future adapters: reject unsupported schema versions, malformed identifiers, non-finite/out-of-range numeric values where a bounded domain applies, malformed digests, and unsafe names before touching storage. Preserve unknown JSON values at every extensible record boundary when round-tripping. These are proposed adapter requirements; where they are stricter than the current platform behavior, migration must be deliberate and must not silently make valid historical v1 data unreadable.

## Reviewed merge policy (C02 target)

`merge-vectors.json` is the integrator-reviewed normative target, not a characterization of current adapters. Its cases are abstract semantic records, not schema-valid manifest fixtures; symbolic IDs such as `B1` and `C1` must be replaced with valid UUIDs when adapter tests construct schema-valid v1 inputs. It separates deterministic primary values from recovery candidates and states where v1 cannot carry a recovery result. C02 defines contract expectations only; applying the policy to production merge code belongs to S03/K02.

The target decodes timestamp JSON numbers as finite IEEE-754 binary64 values, rejects non-finite values and values that overflow this representation, and compares the decoded values numerically while preserving valid fractions. These are Foundation-reference-date wall-clock seconds. For an entity ID, merge tombstones by maximum `deletedAt`. A tombstone suppresses a record when `deletedAt >= modifiedAt`: equality deletes, and an edit survives only when its timestamp is strictly greater. Keep the winning tombstone alongside a strictly newer surviving record. Tombstone garbage collection and expiry of recovery candidates are outside v1.

When records of the same ID and timestamp compete, select a stable primary by RFC 8785/JCS canonical JSON over known portable fields, comparing canonical UTF-8 bytes lexicographically and selecting the smaller value. Exclude device-local paths, credentials, and provider configuration. A digest may accelerate equality checks, but cannot be the only collision comparator. For books, compare the portable `{ "book", "sha256" }` entry. For conversations, select a portable metadata base by the same rule, then merge messages independently.

Union messages by canonical UUID ID. Identical complete messages deduplicate; order the result by `createdAt` ascending and canonical UUID ascending. If one ID names distinct message payloads, select the JCS-first complete message as primary and retain every distinct candidate in durable local recovery. At an equal book timestamp, retain every distinct complete book entry in recovery, including entries with metadata differences or different content identity. Unknown fields are opaque complete JSON values: union different field names, coalesce identical values at the same name, and retain differing same-name values as recovery candidates while selecting the JCS-first value as primary. Do not recursively combine unknown objects or arrays.

Repeated application, duplicate provider snapshots, provider-order permutations for the same inputs, and retry after a destination failure must produce the same semantic primary state and recovery candidate set. This is a merge/replay property, not a transactional-write guarantee. Current v1 adapters unconditionally rewrite `manifest.json`; simultaneous writers can overwrite changes they have not read. C02 cannot promise lossless concurrent writes without conditional writes or a separate operation-log protocol.

Recovery boundaries matter: S03/K02 can implement durable local recovery for conflicting candidates while keeping the v1 primary record. The v1 manifest has no defined way to carry multiple candidate values for one book/message ID or one unknown-field name. Cross-device/provider recovery therefore cannot be represented safely without a reviewed protocol extension; unknown fields are not an ad hoc recovery channel. V1 timestamps are wall-clock values, not causal clocks. The comparison stays deterministic under skew, but it cannot infer real event order: a skewed edit can outlive a real deletion, or a skewed tombstone can suppress a real edit.

Current code is not yet consistent with the C02 merge target. In both implementations deletion wins timestamp equality, but book/chat equal-time choices are generally local/first-operand biased. Chats currently union message IDs and sort by time/ID, while a duplicate ID with different content silently keeps the later iterated value. Both platforms preserve unknown fields through their codecs. Multi-provider sync uses sequential passes when multiple destinations are selected, but does not provide conditional manifest writes. See `Apps/Shared/BookLibrary.swift`, `AIService.swift`, and `RemoteStorage.swift`; Android equivalents are `Apps/Android/app/src/main/kotlin/io/github/haige120/cloudreader/data/LibraryRepository.kt`, `sync/SyncCodec.kt`, and `sync/SyncEngine.kt`.

## Files

- `schema.json`: JSON Schema draft 2020-12 for the v1 wire envelope. It models legacy optional/defaulted fields and permits extension members. Safety checks requiring cross-platform policy are called out in this prose and fixtures.
- `fixtures/*.json`: one input per case with expected outcome/adoption notes in a sibling `.expected.json` file. Outcomes distinguish parse characterization, safety rejection expectation, and preservation expectations.
- `merge-vectors.json`: reviewed C02 merge policy and deterministic vectors. Swift/Kotlin tests and production merge code have not adopted it yet.

## Adoption map

| Fixture | iOS/macOS consumer | Android consumer | Gate / task |
| --- | --- | --- | --- |
| `minimal-legacy` | Legacy defaults, date units and decode behavior | Legacy defaults, date units and decode behavior | GCONTRACT, S01.c; K01 |
| `full-record`, `mixed-case-uuid` | Typed values, UUID identity and fractional dates | Wire/domain values, UUID identity and fractional dates | GCONTRACT, S01.c; K01 |
| `unknown-format`, `unknown-role` | Reject unsupported format; retain unknown role raw value | Reject unsupported format; retain arbitrary role strings | GCONTRACT, S01/S01.c; K01 |
| `nested-unknown` | Lossless durable round-trip at every listed boundary | Lossless durable round-trip at every listed boundary | GCONTRACT, S01; K01.b |
| `malformed-hash`, `unsafe-filename`, `invalid-number`, `out-of-range-progress`, `unsupported-version` | Reject safely before storage or publication | Reject safely before storage or publication | GCONTRACT, S01.c; K01.b |
| `deletion-equal-time` | Parse only here; later merge expectation belongs to C02/S03 | Parse only here; later merge expectation belongs to C02/K02 | GCONTRACT; GSYNC after C02 |
| `merge-vectors.json` | Shared semantic merge target; adapter tests substitute valid UUIDs/manifests | Shared semantic merge target; adapter tests substitute valid UUIDs/manifests | GCONTRACT/GSYNC; C02 then S03/K02 |

C01 supplies immutable inputs and expected semantic outcomes. Adapter adoption is complete only when Swift and Kotlin tests read these same files, assert the expected outcomes, and record any legacy characterization separately from normative behavior. K01 covers all inputs on Android; S01.c covers them on Apple and enforces remote preflight safety checks.

This draft intentionally defines no v2 fields.
