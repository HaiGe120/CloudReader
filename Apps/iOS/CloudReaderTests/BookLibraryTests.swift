import Foundation
import CloudReaderCore
import XCTest
@testable import CloudReader

@MainActor
final class BookLibraryTests: XCTestCase {
    private final class SelectiveFailingRepository: LibraryRepository {
        let base: JSONLibraryRepository
        var failNextBooksSave = false

        init(root: URL) { base = JSONLibraryRepository(root: root) }
        func load() -> LibrarySnapshot { base.load() }
        func save(_ snapshot: LibrarySnapshot, collections: Set<LibraryCollection>) throws {
            if failNextBooksSave && collections.contains(.books) {
                failNextBooksSave = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try base.save(snapshot, collections: collections)
        }
    }

    private func makeIsolatedLibrary() -> (library: BookLibrary, storageDirectory: URL, defaults: UserDefaults) {
        let identifier = UUID().uuidString
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudReaderTests-\(identifier)", isDirectory: true)
        let suiteName = "CloudReaderTests.\(identifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: storageDirectory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (BookLibrary(storageDirectory: storageDirectory, defaults: defaults), storageDirectory, defaults)
    }

    private func nestedUnknownManifest() throws -> RemoteLibraryManifest {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../Contracts/v1/fixtures/nested-unknown.json")
            .standardizedFileURL
        return try JSONDecoder().decode(RemoteLibraryManifest.self, from: Data(contentsOf: fixtureURL))
    }

    func testImportPreservesOriginalAndSavesLocalReadingState() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudReader-\(UUID().uuidString).txt")
        let original = Data("A reader should keep its place.\n继续阅读。".utf8)
        try original.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let isolated = makeIsolatedLibrary()
        let library = isolated.library
        library.importBooks(from: [source])

        let book = try XCTUnwrap(library.books.first)
        let storedCopy = try XCTUnwrap(library.fileURL(for: book))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: storedCopy), original)

        library.updateProgress(for: book.id, to: 0.6)
        library.toggleBookmark(book)

        let reloadedLibrary = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        let reloadedBook = try XCTUnwrap(reloadedLibrary.books.first(where: { $0.id == book.id }))
        XCTAssertEqual(reloadedBook.progress, 0.6, accuracy: 0.001)
        XCTAssertTrue(reloadedBook.isBookmarked)
        XCTAssertNotNil(reloadedBook.briefDescription)

        library.remove(book)
    }

    func testInjectedRepositoryFailureRollsBackImportAndDelete() throws {
        let isolated = makeIsolatedLibrary()
        try FileManager.default.createDirectory(at: isolated.storageDirectory, withIntermediateDirectories: true)
        let source = isolated.storageDirectory.appendingPathComponent("source.txt")
        try Data("A safely imported book.".utf8).write(to: source)
        let repository = SelectiveFailingRepository(root: isolated.storageDirectory)
        let library = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults, repository: repository)

        repository.failNextBooksSave = true
        library.importBooks(from: [source])
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: isolated.storageDirectory.appendingPathComponent("Books").path).isEmpty) ?? true)

        let seeded = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        seeded.importBooks(from: [source])
        let book = try XCTUnwrap(seeded.books.first)
        let deleteRepository = SelectiveFailingRepository(root: isolated.storageDirectory)
        let deleteLibrary = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults, repository: deleteRepository)
        deleteRepository.failNextBooksSave = true

        deleteLibrary.remove(book)

        XCTAssertEqual(deleteLibrary.books.map(\.id), [book.id])
        XCTAssertTrue(deleteLibrary.deletedBooks.isEmpty)
        XCTAssertNotNil(deleteLibrary.fileURL(for: book))
    }

    func testFailedSyncedDeletionKeepsBookRecordAndManagedBytes() throws {
        let isolated = makeIsolatedLibrary()
        try FileManager.default.createDirectory(at: isolated.storageDirectory, withIntermediateDirectories: true)
        let repository = SelectiveFailingRepository(root: isolated.storageDirectory)
        let library = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults, repository: repository)
        let source = isolated.storageDirectory.appendingPathComponent("source.txt")
        try Data("keep until deletion is durable".utf8).write(to: source)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        let managedURL = try XCTUnwrap(library.fileURL(for: book))

        repository.failNextBooksSave = true
        library.applySyncedDeletion(BookDeletion(bookID: book.id, deletedAt: .distantFuture))

        XCTAssertEqual(library.books.first?.id, book.id)
        XCTAssertTrue(library.deletedBooks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
        let reopened = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        XCTAssertEqual(reopened.books.first?.id, book.id)
    }

    func testMissingManagedCopyCanBeRestoredBySyncedContent() throws {
        let isolated = makeIsolatedLibrary()
        try FileManager.default.createDirectory(at: isolated.storageDirectory, withIntermediateDirectories: true)
        let source = isolated.storageDirectory.appendingPathComponent("source.txt")
        try Data("Original contents".utf8).write(to: source)
        let library = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        try FileManager.default.removeItem(at: XCTUnwrap(library.fileURL(for: book)))

        XCTAssertNil(library.fileURL(for: book))
        XCTAssertTrue(library.applySyncedBook(book, contents: Data("Restored contents".utf8)))
        XCTAssertEqual(library.data(for: try XCTUnwrap(library.books.first)), Data("Restored contents".utf8))
    }

    func testSupportedFileExtensionsAreCaseInsensitive() {
        XCTAssertEqual(BookFormat(fileExtension: "EPUB"), .epub)
        XCTAssertEqual(BookFormat(fileExtension: "pdf"), .pdf)
        XCTAssertEqual(BookFormat(fileExtension: "txt"), .txt)
        XCTAssertEqual(BookFormat(fileExtension: "exe"), nil)
    }

    func testLegacyBookRecordsDecodeWithoutModifiedAt() throws {
        let original = Book(title: "Legacy", fileName: "legacy.txt", format: .txt)
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "modifiedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let restored = try JSONDecoder().decode(Book.self, from: legacyData)
        XCTAssertEqual(restored.modifiedAt, original.addedAt)
        XCTAssertEqual(restored.progress, 0)
        XCTAssertFalse(restored.isBookmarked)
        XCTAssertNil(restored.briefDescription)

        var described = original
        described.briefDescription = "A short description for the reader."
        let describedData = try JSONEncoder().encode(described)
        let decodedDescription = try JSONDecoder().decode(Book.self, from: describedData)
        XCTAssertEqual(decodedDescription.briefDescription, described.briefDescription)
    }

    func testManagedLibraryRejectsRemotePathTraversal() {
        let library = makeIsolatedLibrary().library
        let hostileRecord = Book(title: "Outside", fileName: "../outside.pdf", format: .pdf)
        XCTAssertNil(library.fileURL(for: hostileRecord))
    }

    func testAIConversationIsSavedLocallyAndRestoredFromHistory() throws {
        let isolated = makeIsolatedLibrary()
        let library = isolated.library
        let id = UUID()
        let record = AIConversationRecord(
            id: id,
            messages: [.user("What does this passage mean?"), .assistant("It explains the central idea.")],
            bookID: UUID(),
            bookTitle: "The Open Shelf",
            selectedText: "Your books should feel like yours.",
            includeBookContext: true
        )

        library.saveAIConversation(record)

        let reloaded = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        let restored = try XCTUnwrap(reloaded.aiConversations.first(where: { $0.id == id }))
        XCTAssertEqual(restored.messages.map(\.text), ["What does this passage mean?", "It explains the central idea."])
        XCTAssertEqual(restored.bookTitle, "The Open Shelf")
        XCTAssertEqual(restored.selectedText, "Your books should feel like yours.")
        XCTAssertTrue(restored.includeBookContext)

        reloaded.removeAIConversation(restored)
    }

    func testConcurrentConversationMessagesMergeWithoutLoss() {
        let originalQuestion = AIConversationMessage.user("Explain this idea.")
        let base = AIConversationRecord(id: UUID(), messages: [originalQuestion])
        var local = base
        local.messages.append(.assistant("A local response."))
        local.modifiedAt = Date(timeIntervalSince1970: 10)
        var remote = base
        remote.messages.append(.assistant("A response from another device."))
        remote.modifiedAt = Date(timeIntervalSince1970: 11)

        let merged = local.merging(remote)

        XCTAssertEqual(merged.messages.count, 3)
        XCTAssertEqual(Set(merged.messages.map(\.id)).count, 3)
        XCTAssertEqual(merged.messages.first?.id, originalQuestion.id)
        XCTAssertEqual(merged.modifiedAt, remote.modifiedAt)
    }

    func testEqualTimeConversationAndMessageCollisionsArePermutationStable() {
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let timestamp = Date(timeIntervalSinceReferenceDate: 20)
        let a = AIConversationRecord(id: conversationID, title: "Alpha", messages: [
            AIConversationMessage(id: messageID, role: .user, text: "original", createdAt: timestamp)
        ], createdAt: timestamp, modifiedAt: timestamp)
        let b = AIConversationRecord(id: conversationID, title: "Beta", messages: [
            AIConversationMessage(id: messageID, role: .user, text: "different", createdAt: timestamp)
        ], createdAt: timestamp, modifiedAt: timestamp)

        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).merging(a), a.merging(b))
    }

    func testOldSyncManifestDecodesWithoutConversationFields() throws {
        let legacy = Data(#"{"schemaVersion":1,"updatedAt":0,"books":[],"deletions":[]}"#.utf8)

        let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: legacy)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertTrue(manifest.conversations.isEmpty)
        XCTAssertTrue(manifest.conversationDeletions.isEmpty)
    }

    func testUnknownFieldsSurviveLocalSaveReloadAndKnownFieldReplacement() throws {
        let manifest = try nestedUnknownManifest()
        let isolated = makeIsolatedLibrary()
        let library = isolated.library
        var book = try XCTUnwrap(manifest.books.first?.book)
        let originalBookID = book.id
        XCTAssertTrue(library.applySyncedBook(book, contents: Data("fixture book".utf8)))
        book.title = "Edited locally"
        XCTAssertTrue(library.applySyncedBook(book, contents: Data("replacement book".utf8)))
        library.updateProgress(for: book.id, to: 0.4)
        library.flushPendingChanges()
        if let deletion = manifest.deletions.first { library.applySyncedDeletion(deletion) }

        var conversation = try XCTUnwrap(manifest.conversations.first)
        library.applySyncedAIConversation(conversation)
        conversation.messages[0].text = "Edited question"
        library.saveAIConversation(conversation)

        let reloaded = BookLibrary(storageDirectory: isolated.storageDirectory, defaults: isolated.defaults)
        let restoredBook = try XCTUnwrap(reloaded.books.first(where: { $0.id == originalBookID }))
        XCTAssertEqual(restoredBook.title, "Edited locally")
        XCTAssertEqual(restoredBook.progress, 0.4, accuracy: 0.001)
        let restoredConversation = try XCTUnwrap(reloaded.aiConversations.first)
        XCTAssertEqual(restoredConversation.messages.first?.text, "Edited question")
        XCTAssertEqual(restoredConversation.messages.first?.role, .unknown("futureRole"))

        func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        let bookObject = try encodedObject(restoredBook)
        XCTAssertNotNil(bookObject["futureBook"])
        let restoredDeletion = try XCTUnwrap(reloaded.deletedBooks.first)
        let deletionObject = try encodedObject(restoredDeletion)
        XCTAssertNotNil(deletionObject["futureTombstone"])
        let conversationObject = try encodedObject(restoredConversation)
        XCTAssertNotNil(conversationObject["futureConversation"])
        let messageObject = try XCTUnwrap((conversationObject["messages"] as? [[String: Any]])?.first)
        XCTAssertNotNil(messageObject["futureMessage"])
    }

    func testSyncManifestRoundTripsConversationMessagesAndReaderContext() throws {
        let savedConversation = AIConversationRecord(
            title: "Explain the highlighted passage",
            messages: [.user("What does this mean?"), .assistant("It introduces the main idea.")],
            bookTitle: "The Open Shelf",
            selectedText: "Your books should feel like yours.",
            includeBookContext: true
        )
        var manifest = RemoteLibraryManifest()
        manifest.conversations = [savedConversation]

        let data = try JSONEncoder().encode(manifest)
        let restored = try JSONDecoder().decode(RemoteLibraryManifest.self, from: data)

        XCTAssertEqual(restored.conversations, [savedConversation])
        XCTAssertEqual(restored.conversations.first?.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(restored.conversations.first?.selectedText, "Your books should feel like yours.")
    }

    func testMultipleCloudDestinationsPersistWithoutDuplicates() {
        let isolated = makeIsolatedLibrary()
        let defaults = isolated.defaults
        let sync = CloudSyncCoordinator(defaults: defaults)
        sync.selectedProviders = [.googleDrive, .dropbox, .googleDrive]

        XCTAssertEqual(sync.selectedProviders, [.googleDrive, .dropbox])
        XCTAssertEqual(defaults.stringArray(forKey: "cloudreader.providers"), ["googleDrive", "dropbox"])
    }

    func testReaderPaginationPreservesLongWordsAndPageBoundaries() {
        let source = String(repeating: "ordinary words and continued reading ", count: 35) + String(repeating: "界", count: 75)
        let pages = ReaderPagination.pages(from: source, maximumCharacters: 120)
        let normalizedSource = source.filter { !$0.isWhitespace }
        let normalizedPages = pages.joined().filter { !$0.isWhitespace }

        XCTAssertEqual(normalizedPages, normalizedSource)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 120 })
    }

    func testReaderPaginationHandlesEmptyAndShortBooks() {
        XCTAssertEqual(ReaderPagination.pages(from: "", maximumCharacters: 100), [""])
        XCTAssertEqual(ReaderPagination.pages(from: "A short page.", maximumCharacters: 100), ["A short page."])
    }

    func testReaderFacingPagesFitAvailableTextAreaAndKeepCJKCharacters() {
        let source = String(repeating: "A paragraph with readable words.\n\n", count: 24) + String(repeating: "继续阅读云端书架。", count: 90)
        let font = ReaderFont.systemSerif.uiFont(size: 18)
        let pages = ReaderPagination.pages(from: source, width: 320, height: 360, font: font)

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
        XCTAssertTrue(pages.allSatisfy { ReaderPagination.measuredHeight(of: $0, width: 320, font: font) <= 360 })
    }

    func testPageTurnProgressRestoresTheSamePageOrSpread() {
        for pagesPerGroup in [1, 2] {
            let pageCount = 7
            let groupCount = ReaderPagination.pageGroupCount(pageCount: pageCount, pagesPerGroup: pagesPerGroup)

            for group in 0..<groupCount {
                let progress = ReaderPagination.progress(
                    pageGroupIndex: group,
                    pageCount: pageCount,
                    pagesPerGroup: pagesPerGroup
                )
                XCTAssertEqual(
                    ReaderPagination.pageGroupIndex(progress: progress, pageCount: pageCount, pagesPerGroup: pagesPerGroup),
                    group
                )
            }
        }

        XCTAssertEqual(ReaderPagination.pageGroupIndex(progress: 0, pageCount: 7, pagesPerGroup: 1), 0)
        XCTAssertEqual(ReaderPagination.pageGroupIndex(progress: 1, pageCount: 7, pagesPerGroup: 2), 3)
    }

    func testOpenAIChatCompletionsPayloadAndResponse() throws {
        var profile = AIProviderConfiguration()
        profile.endpointKind = .openAIChatCompletions
        profile.model = "test-model"
        let data = try AIService.makePayload(profile: profile, messages: [.user("Explain this." )], instructions: "Be concise.")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(payload["model"] as? String, "test-model")
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.last?["content"], "Explain this.")

        let response = Data(#"{"choices":[{"message":{"content":"A concise answer."}}]}"#.utf8)
        XCTAssertEqual(AIService.decodeAnswer(from: response, kind: .openAIChatCompletions), "A concise answer.")
    }

    func testOpenAIResponsesPayloadAndResponse() throws {
        var profile = AIProviderConfiguration()
        profile.endpointKind = .openAIResponses
        profile.model = "test-model"
        let data = try AIService.makePayload(profile: profile, messages: [.user("What is the point?")], instructions: "Use the excerpt.")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [[String: String]])
        XCTAssertEqual(input.first?["role"], "developer")
        XCTAssertEqual(input.last?["role"], "user")

        let response = Data(#"{"output_text":"The point is to keep reading state portable."}"#.utf8)
        XCTAssertEqual(AIService.decodeAnswer(from: response, kind: .openAIResponses), "The point is to keep reading state portable.")
    }

    func testAnthropicMessagesPayloadAndResponse() throws {
        var profile = AIProviderConfiguration()
        profile.endpointKind = .anthropicMessages
        profile.model = "test-model"
        let data = try AIService.makePayload(profile: profile, messages: [.user("Define a library index.")], instructions: "Answer clearly.")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["max_tokens"] as? Int, 1200)
        XCTAssertEqual(payload["system"] as? String, "Answer clearly.")

        let response = Data(#"{"content":[{"type":"text","text":"A portable list of books and state."}]}"#.utf8)
        XCTAssertEqual(AIService.decodeAnswer(from: response, kind: .anthropicMessages), "A portable list of books and state.")
    }

    func testReaderContextIsIncludedSeparatelyFromTheUsersQuestion() throws {
        var profile = AIProviderConfiguration()
        profile.model = "test-model"
        let question = "Why does this sentence matter to the chapter?"
        let instructions = AIService.makeInstructions(
            baseInstructions: "Answer the reader's question.",
            bookTitle: "The Open Shelf",
            bookDescription: "A field guide to CloudReader's reader experience and sync design.",
            selectedText: "Your books should feel like yours."
        )
        let data = try AIService.makePayload(profile: profile, messages: [.user(question)], instructions: instructions)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap(payload["input"] as? [[String: String]])

        XCTAssertTrue(input.first?["content"]?.contains("The Open Shelf") == true)
        XCTAssertTrue(input.first?["content"]?.contains("brief_description") == true)
        XCTAssertTrue(input.first?["content"]?.contains("Your books should feel like yours.") == true)
        XCTAssertEqual(input.last?["content"], question)
        XCTAssertFalse(input.first?["content"]?.contains(question) == true)
    }

    func testGoogleDriveOAuthUsesTheIOSClientsReversedRedirectScheme() throws {
        let request = try OAuthConnector.authorizationRequest(
            kind: .googleDrive,
            clientID: "1234567890-example.apps.googleusercontent.com",
            state: "test-state",
            challenge: String(repeating: "a", count: 43)
        )
        let parameters = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(request.callbackScheme, "com.googleusercontent.apps.1234567890-example")
        XCTAssertEqual(request.redirectURI, "com.googleusercontent.apps.1234567890-example:/oauth2redirect")
        XCTAssertEqual(parameters.first(where: { $0.name == "redirect_uri" })?.value, request.redirectURI)
        XCTAssertEqual(parameters.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(parameters.first(where: { $0.name == "scope" })?.value, "https://www.googleapis.com/auth/drive.appdata")
    }

    func testDropboxOAuthUsesTheAppSpecificCallbackAndRequiredFileScopes() throws {
        let request = try OAuthConnector.authorizationRequest(
            kind: .dropbox,
            clientID: "cloudreader123",
            state: "test-state",
            challenge: String(repeating: "b", count: 43)
        )
        let parameters = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let scope = parameters.first(where: { $0.name == "scope" })?.value ?? ""

        XCTAssertEqual(request.callbackScheme, "db-cloudreader123")
        XCTAssertEqual(request.redirectURI, "db-cloudreader123://2/token")
        XCTAssertEqual(parameters.first(where: { $0.name == "redirect_uri" })?.value, request.redirectURI)
        XCTAssertTrue(scope.contains("files.content.read"))
        XCTAssertTrue(scope.contains("files.content.write"))
        XCTAssertTrue(scope.contains("files.metadata.read"))
        XCTAssertTrue(scope.contains("files.metadata.write"))
    }

    func testPCloudOAuthUsesMobileTokenCallback() throws {
        let request = try OAuthConnector.authorizationRequest(
            kind: .pCloud,
            clientID: "pcloud-app-id",
            state: "test-state",
            challenge: String(repeating: "c", count: 43)
        )
        let parameters = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(request.callbackScheme, "cloudreader")
        XCTAssertEqual(request.redirectURI, "cloudreader://pcloud-oauth")
        XCTAssertEqual(parameters.first(where: { $0.name == "response_type" })?.value, "token")
        XCTAssertEqual(parameters.first(where: { $0.name == "state" })?.value, "test-state")
    }
}
