# CloudReader product and platform specification

This is the canonical product brief for CloudReader across iOS, macOS, Android, Windows, and Linux. Keep platform plans, shared data rules, security decisions, and feature status here so each client can be implemented against the same expectations. Update the status table when behavior ships or changes.

## Product goal

CloudReader is a polished, offline-first reader that lets people keep DRM-free books and reading state together across their own devices. It requires no CloudReader account or CloudReader-hosted service. A reader chooses a cloud provider or folder they control. The local library remains usable when offline, and importing a book copies it into managed storage without changing the original file.

The product is built in phases. The native iOS app targets iOS 26 or later with SwiftUI and the system's Liquid Glass controls. The native macOS app targets macOS 15 or later. Both Apple targets compile the same Swift sources from `Apps/Shared` for the book model, library, provider sync, AI service, and Ask CloudReader App Intent, while using separate native SwiftUI screens. The Android client is a Kotlin and Jetpack Compose app targeting Android 12+ (API 31), with application ID `io.github.haige120.cloudreader`; it follows the same portable schema while keeping format-specific reading positions local. Windows and Linux remain future clients governed by these contracts. There is no web app in the current product plan.

## Product principles

- Keep reading available offline and preserve the imported source file.
- Make book files and reading records exportable without provider credentials.
- Use stable book identities, content hashes, versioned metadata, and recoverable deletions so devices can reconcile after being offline.
- Let each device select multiple connected storage destinations. Merge each destination's state into the local library, then fan the merged library out to every selected destination. Do not make the sync protocol depend on one vendor's account model.
- Store API keys, OAuth refresh tokens, and storage passwords in the operating system's secure credential store. Never write them into a sync index, book file, debug log, or export.
- Ask before sending a book excerpt to an AI provider. Never upload a whole library automatically.
- Use native interaction patterns and accessible controls on each platform while preserving the same portable data meaning.

## Platform sequence

1. **iOS:** native SwiftUI app, iPhone and iPad layouts, current iOS 26+ target. Include iPhone Duo and other wide/compact postures in layout testing.
2. **macOS:** native desktop reader using the same library index, AI profile model, storage adapters, and portable position records. Local library, adjustable TXT and PDF layouts, EPUB reader, foreground sync, remote AI, and Apple Foundation Models integration are implemented. Google Drive uses a Desktop OAuth client and local loopback callback; provider app identifiers remain in Settings.
3. **Android:** native Kotlin/Compose app for phones, tablets, and foldables; first delivery is an installable debug APK. Current implementation is in `Apps/Android`.
4. **Windows and Linux:** desktop readers using the shared format and provider behavior, with OS-native credential stores and file pickers.

All clients must be able to exchange a library created by another client. A platform-specific reader may store a location it understands, but it must preserve unknown optional metadata when it rewrites a record.

## Library and reading data

Every book has a stable UUID, title, optional author, format, managed local filename, added time, last-opened time, normalized progress fraction, favorite/bookmark flag, and modified time. Book bytes are stored separately from metadata. Imported source files remain untouched. The current iOS implementation reads EPUB, PDF, and TXT; MOBI, AZW3, FB2, CBZ, and CBR can be retained in the library while their native readers are future work.

Reading adapters should represent position in a format-aware way in addition to normalized progress:

| Format | Portable location goal | Progress summary |
| --- | --- | --- |
| EPUB | Canonical EPUB CFI or equivalent stable spine-and-offset anchor | Fraction through the publication |
| PDF | Zero-based page index, optionally with page point/selection | Current page divided by page count |
| TXT | Stable byte or Unicode-scalar offset plus encoding | Offset divided by readable length |
| Comic archive | Ordered image entry plus optional panel/scroll location | Current image and position divided by total |

Annotations and in-book bookmarks should have their own stable IDs, book ID, portable anchor, created/modified times, and optional note or highlight content. A platform that does not understand a reader-specific anchor must preserve it without moving it. The current app's `isBookmarked` field is a library favorite; it is not yet an in-book annotation.

### Sync files and index

The current Apple-target wire format uses `manifest.json` as the library index and separate content objects named `book-<book UUID>.<extension>`. Each manifest book entry contains the portable `Book` record—including progress and the library bookmark flag—and SHA-256 of the bytes. The manifest also stores AI conversation transcripts and their saved reader context, schema version, index update time, and deletion tombstones. Conversation messages have stable IDs and timestamps so offline additions can merge. Devices validate downloaded book objects against their hashes before installing them. API credentials are kept outside this directory.

The detailed schema-v1 field/default rules, JSON Schema, fixture cases, and current adapter compatibility notes live in the [portable sync contract](../Contracts/v1/README.md). The contract is a draft interoperability target: shared fixtures define expected outcomes without claiming that both current platforms already satisfy unknown-field preservation or every safety check.

In schema v1, `Book.fileName` describes the managed file on the device that last wrote the record. Receivers replace it with a safe local filename after downloading; providers derive the remote object name from the stable book UUID and format. Cross-platform clients must keep local paths separate from remote object paths and must never trust a synced filename as a filesystem path.

Current manifest shape (dates are encoded by Swift's JSONEncoder in the iOS build):

```json
{
  "schemaVersion": 1,
  "updatedAt": 0,
  "books": [
    {
      "book": {
        "id": "00000000-0000-0000-0000-000000000000",
        "title": "A title",
        "author": "An author",
        "fileName": "local-file-name.epub",
        "format": "epub",
        "addedAt": 0,
        "lastOpenedAt": 0,
        "progress": 0.42,
        "isBookmarked": false,
        "modifiedAt": 0
      },
      "sha256": "hex-encoded-content-hash"
    }
  ],
  "deletions": [
    { "bookID": "00000000-0000-0000-0000-000000000000", "deletedAt": 0 }
  ],
  "conversations": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "title": "A saved question",
      "messages": [
        { "id": "00000000-0000-0000-0000-000000000001", "role": "user", "text": "What does this passage mean?", "createdAt": 0 },
        { "id": "00000000-0000-0000-0000-000000000002", "role": "assistant", "text": "It means…", "createdAt": 1 }
      ],
      "bookID": "00000000-0000-0000-0000-000000000003",
      "bookTitle": "A title",
      "selectedText": "A passage the reader chose to include",
      "includeBookContext": true,
      "createdAt": 0,
      "modifiedAt": 1
    }
  ],
  "conversationDeletions": []
}
```

`0` values above illustrate JSON number fields; actual dates are Foundation reference-date timestamps. New conversation fields are optional when decoding older schema-v1 manifests. Concurrent copies of a chat merge messages by stable ID and timestamp; book metadata follows the later `modifiedAt`. A deletion wins over a record that is not newer than its tombstone. Preserve tombstones through sync so disconnected devices cannot silently resurrect removed books or chats. The app should report failed syncs, keep local data, and retry after reconnection.

### Portable v2 direction

Before adding additional clients, evolve the sync index to a documented cross-platform schema with a stable `libraryID`, explicit format identifier, canonical content hash and object path, ISO-8601 timestamps, reader-specific position records, and separate annotation/bookmark records. Include a migration reader for schema version 1. Unknown fields must round-trip. Concurrent reading updates should eventually retain both device versions and offer a user choice instead of discarding a position through last-write-wins. Keep book file transfer independent from small metadata updates.

Exports contain book bytes and portable metadata, positions, favorites, annotations, and deletion/restore information. They must exclude all credentials and session tokens.

## Storage and sync providers

Multiple providers/folders can be selected as sync destinations for a library. Other mounted locations remain available as import sources. Provider adapters implement a small read/write object interface and share the same index and book-object format. During a multi-destination sync, CloudReader merges each selected destination with its local library and repeats the merge pass so content discovered in one destination is also copied to the others.

| Provider | Integration plan/status |
| --- | --- |
| Google Drive | Direct adapter using Drive's app-specific data area and user OAuth; request only needed scope. |
| Dropbox | Direct adapter using scoped OAuth and its file API. |
| pCloud | Direct OAuth adapter; stores a private CloudReader folder and follows the account's returned API region. |
| WebDAV | Direct HTTPS adapter for Nextcloud, ownCloud, and compatible servers. |
| SFTP | Direct adapter with server identity verification and secure credential storage. |
| iCloud Drive | Apple document/file integration on iOS and macOS; folder-based sync. |
| SMB | Native/platform file provider when exposed by the OS; iOS uses a folder selected in Files. A direct SMB client is not part of the current iOS build. |
| MEGA | Direct adapter remains future work; MEGA's official client SDK is C++ with native iOS bindings, so this requires a maintained iOS bridge. A Files-provider folder can be used when exposed by the installed app. |
| PikPak | Direct iOS adapter remains future work; the official public SDK material currently describes a Telegram Android SDK and developer-service enrollment. A Files-provider folder can be used when exposed by the installed app. |
| OneDrive, Box, S3-compatible, local synced folders | Future direct adapters as the target platform needs justify them; on iOS, folders from provider apps may be used if those apps expose them in Files. |

The iOS and macOS sync coordinators sync while their app is foregrounded and after local library or conversation changes. Managed books, progress, bookmark flags, deletion records, and all saved AI conversations are stored locally and synchronized to every selected destination. Conversation context, such as a selected passage, travels with its chat. Select matching destinations on each device; connections and credentials are set up separately on each device. Sync visits destinations sequentially in the foreground, and a later pass propagates changes discovered in another destination. Background-transfer scheduling and explicit reading-position conflict resolution are follow-on work. WebDAV requires HTTPS. SFTP server keys must be checked against a pin or trusted host-key store.

## AI assistant

AI is optional. A person configures one active profile and chooses either a remote API or Apple's on-device Foundation Model. Remote profiles include a display name, model ID, optional full endpoint URL, and an API key. Keys are stored in Keychain on Apple platforms and an equivalent secure store on other systems. The client makes direct HTTPS requests to the configured endpoint; CloudReader does not proxy requests. Apple's model runs through Foundation Models on iOS 26+ or macOS 26+ when the device, region, and Apple Intelligence settings make it available; the app checks availability and reports a fallback message. Chat messages are saved locally and synchronized to every selected destination with any saved book context. Provider API keys are never synchronized.

Supported protocol shapes:

| Protocol | Request/response contract |
| --- | --- |
| OpenAI Chat Completions | `POST /v1/chat/completions`, message list, read `choices[0].message.content`. |
| OpenAI Responses | `POST /v1/responses`, role-based input, read `output_text` or text output content. |
| Anthropic Messages | `POST /v1/messages`, `x-api-key`, `anthropic-version`, required `max_tokens`, text content blocks. |
| Custom endpoint | User-provided full endpoint URL using one of the three protocol shapes above; HTTPS is required except localhost for development. |

The reader may ask general questions or optionally attach a bounded text excerpt from a supported book. The user sees and controls that choice. The shared Ask CloudReader App Intent uses the active provider, including the on-device model when selected. iOS includes a built-in Siri phrase; on macOS, App Shortcuts are unsupported, but the App Intent can be added to a custom action in the Shortcuts app. Android uses remote AI and the Android share sheet. Siri's Apple Intelligence ChatGPT extension is configured by the user at system level; CloudReader does not control or impersonate that integration. The assistant can share prompt text through the iOS share sheet so the user can choose another app, including ChatGPT if it appears as an available destination. Do not rely on private ChatGPT URL schemes.

Conversation history is stored locally and included in library sync. Chats and messages have stable IDs and Foundation reference-date timestamps; deletions use tombstones. Provider credentials and AI settings remain device-local. Never attach book text to a request launched from Siri unless the user explicitly supplies it in the question. Show useful failures for invalid endpoint, missing key, authentication failure, rate limits, and unreadable responses.

## User experience and accessibility

Use native system controls and materials. Book pages prioritize legibility over decorative effects. Layouts adapt to compact and expanded width, portrait/landscape, foldable posture, and desktop windows; wide iPhone layouts should use the added space for a featured book, sync state, and shelf rather than simply stretching a narrow column. Respect Dynamic Type, VoiceOver/TalkBack/Narrator, keyboard navigation, high contrast, reduce motion, and reduce transparency. Status must be readable without color alone.

Wide reading surfaces should offer single-page scrolling and facing-page spreads with horizontal page turns. Text books should provide system, light, sepia, dark, and reader-defined paper/text colors plus multiple fonts and adjustable type size. PDF remains fixed-layout: offer PDFKit two-up pages and a themed reading canvas, while leaving the document's ink and typography intact. iOS and macOS EPUB use an in-app chapter reader with cached archive preparation, chapter navigation, adjustable typography/themes, selected-passage AI, and normalized chapter/scroll progress. Android uses Readium's EPUB navigator and keeps its precise locator on-device.

Selecting text in a supported reader should expose an **Ask CloudReader AI** action. The selected passage opens the assistant with a relevant starter question and a clear excerpt-sharing switch; text is not sent until the reader submits. PDF may use a contextual floating action when its native selection menu cannot be extended. Both iOS and macOS EPUB readers expose selected-passage AI.

## iOS implementation status

| Feature | Status |
| --- | --- |
| SwiftUI app, iOS 26+, native glass controls | Implemented |
| iPhone Duo expanded/compact responsive library | Implemented; continue visual testing on device postures |
| Wide TXT facing-page reader, adjustable typography and custom themes | Implemented; preferences are device-local |
| PDF two-up layout and selected-passage AI action | Implemented; PDF content remains fixed-layout |
| TXT text-selection menu action to ask AI | Implemented |
| EPUB selected-passage AI, chapter navigation and typography controls | Implemented in the iOS in-app EPUB reader; precise CFI positions remain planned |
| Original CC0 demo book, seeded in the local library | Implemented |
| EPUB, PDF, TXT reader | Implemented with cached in-app EPUB chapters and native PDF/Text views |
| Files picker, Open in CloudReader, share-sheet book import | Implemented; the share extension stages copies for automatic import when CloudReader next becomes active |
| Google Drive, Dropbox, pCloud, HTTPS WebDAV, SFTP sync | Implemented; requires provider app IDs or user server credentials |
| iCloud Drive, SMB, third-party provider folder | Implemented through iOS Files and macOS Finder folder pickers; depends on provider availability in the OS |
| MEGA and PikPak direct OAuth/API sync | Planned; use Files folders when exposed by their installed apps |
| SHA-256 book objects, JSON index, progress/favorites, deletion tombstones | Implemented in schema v1 |
| OpenAI Chat Completions, OpenAI Responses, Anthropic Messages/custom endpoint | Implemented on iOS and macOS; requires the user's own model/key/endpoint |
| Apple Foundation Models on-device AI | Implemented on iOS 26+ and macOS 26+ when Apple Intelligence is available |
| Siri/Shortcuts Ask CloudReader intent | Implemented as a shared App Intent; iOS phrases and Mac custom Shortcuts action |
| EPUB CFI positions, in-book annotations, conflict-choice UI, background sync | Planned |
| macOS client | Implemented: native library, local persistence, paged TXT/PDF layouts, EPUB reader, shared provider sync, desktop Google OAuth, remote AI, on-device AI, and App Intent |
| Android client | Kotlin/Compose app builds as an installable debug APK; unit tests, lint, and an Android 12 instrumentation test for import, duplicate titles, CJK content, unsupported files, and source preservation pass. Offline TXT resume and process recreation were also checked with Wi-Fi disabled on ARM64 Android 12; launch and recreation were checked on Android 16. Full tablet/foldable/accessibility coverage, the broader format matrix, cross-platform sync round trips, and live provider/OAuth checks remain to be completed. |
| Windows, Linux clients | Prototype underway: shared Kotlin/JVM desktop shell with local TXT import/resume; full reader, sync, AI, accessibility, and packaging support remain planned |

## Project checks

For every platform release, verify offline import/read/resume, content hash validation, sync and deletion across two devices, conflict behavior, credential separation, library export, accessibility, and provider authentication failures. The current iOS simulator suite covers local import, persistence, extension matching, legacy record decoding, and path safety; it does not replace live-provider or real-device OAuth testing.
