import Foundation
import CloudReaderCore
import XCTest
@testable import CloudReader

@MainActor
final class BookLibraryImportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudReaderLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testAsyncImportReturnsOnlySuccessfulBooksInSelectionOrderAndKeepsSources() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First_Book.TXT")
        let second = root.appendingPathComponent("Second-Book.txt")
        let missing = root.appendingPathComponent("Unavailable.epub")
        let unsupported = root.appendingPathComponent("unsupported.exe")
        let contents = Data("A sufficiently long opening paragraph for a useful short book description.".utf8)
        try contents.write(to: first)
        try contents.write(to: second)
        try contents.write(to: unsupported)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))

        let result = await library.importBooksAsync(from: [first, missing, second, unsupported, first])

        XCTAssertEqual(result.importedBooks.map(\.title), ["First Book", "Second Book"])
        XCTAssertEqual(library.books.map(\.id), result.importedBooks.map(\.id))
        XCTAssertEqual(result.rejectedFileNames, ["Unavailable.epub", "unsupported.exe"])
        XCTAssertEqual(try Data(contentsOf: first), contents)
        XCTAssertTrue(result.importedBooks.allSatisfy { $0.briefDescription != nil })
        let reloaded = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        XCTAssertEqual(reloaded.books.map(\.id), library.books.map(\.id))
    }

    func testDirectoryWithSupportedExtensionIsRejectedAndAllFailureDoesNotRewriteLibrary() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("folder.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)

        let result = await library.importBooksAsync(from: [source])

        XCTAssertTrue(result.importedBooks.isEmpty)
        XCTAssertEqual(result.rejectedFileNames, ["folder.epub"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("library.json").path))
        let copies = try FileManager.default.contentsOfDirectory(at: storage.appendingPathComponent("Books"), includingPropertiesForKeys: nil)
        XCTAssertTrue(copies.isEmpty)
    }

    func testSuccessfulAsyncImportDoesNotPresentAnAlertBeforeOpening() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("A short book".utf8).write(to: source)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))

        let result = await library.importBooksAsync(from: [source])

        XCTAssertEqual(result.importedBooks.count, 1)
        XCTAssertNil(library.alertMessage)
    }

    func testTinyProgressChangesPersistExactlyWhenReaderClosesAndDoNotRewriteConversations() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("A short book".utf8).write(to: source)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        library.saveAIConversation(AIConversationRecord(messages: [.user("A question")]))
        let historyURL = storage.appendingPathComponent("ai-conversations.json")
        let originalHistory = try Data(contentsOf: historyURL)
        let sentinel = Date(timeIntervalSince1970: 123_456)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: historyURL.path)

        library.updateProgress(for: book.id, to: 0.00125)
        library.updateProgress(for: book.id, to: 0.0025)
        library.flushPendingChanges()

        let reloaded = BookLibrary(storageDirectory: storage)
        XCTAssertEqual(try XCTUnwrap(reloaded.books.first).progress, 0.0025, accuracy: 0.0000001)
        XCTAssertEqual(try Data(contentsOf: historyURL), originalHistory)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: historyURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, sentinel.timeIntervalSince1970, accuracy: 0.01)
    }

    func testNonFiniteProgressDoesNotCorruptSavedLibrary() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("A short book".utf8).write(to: source)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)

        library.updateProgress(for: book.id, to: .nan)
        library.updateProgress(for: book.id, to: .infinity)
        library.flushPendingChanges()

        XCTAssertEqual(library.books.first?.progress, 0)
        XCTAssertEqual(BookLibrary(storageDirectory: storage).books.first?.id, book.id)
    }

    func testMissingLocalCopyKeepsReadingMetadataForCloudRecovery() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("A short book".utf8).write(to: source)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        try FileManager.default.removeItem(at: XCTUnwrap(library.fileURL(for: book)))

        let reloaded = BookLibrary(storageDirectory: storage)

        XCTAssertEqual(reloaded.books.first?.id, book.id)
        XCTAssertNil(reloaded.fileURL(for: book))
    }

    func testReadingContextLimitRejectsZeroAndSupportsUTF16Descriptions() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        let text = "继续阅读。一个足够长的开头段落帮助读者理解这本书的内容，并保留中文文字。"
        try XCTUnwrap(text.data(using: .utf16)).write(to: source)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)

        XCTAssertEqual(book.briefDescription, text)
        XCTAssertNil(library.readingContext(for: book, maximumCharacters: 0))
        XCTAssertNil(library.readingContext(for: book, maximumCharacters: -1))
        XCTAssertEqual(library.readingContext(for: book, maximumCharacters: 12)?.prefix(12), text.prefix(12))
    }

    func testFailedIndexSaveReturnsNoSuccessfulImportsAndKeepsOriginalForRetry() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("A short book".utf8).write(to: source)
        let storage = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        let library = BookLibrary(storageDirectory: storage)

        let result = await library.importBooksAsync(from: [source])

        XCTAssertTrue(result.importedBooks.isEmpty)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNotNil(library.alertMessage)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("Books").path).isEmpty)
    }

    func testSyncedReplacementRemovesSupersededFileOnlyAfterSaving() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        try Data("Original book".utf8).write(to: source)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        let originalCopy = try XCTUnwrap(library.fileURL(for: book))
        let replacement = Data("Synced book".utf8)

        XCTAssertTrue(library.applySyncedBook(book, contents: replacement))

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalCopy.path))
        XCTAssertEqual(library.data(for: try XCTUnwrap(library.books.first)), replacement)
    }

    func testMissingCopyRecoveryKeepsNewerLocalProgressAndBookmarks() {
        var remote = Book(title: "Book", fileName: "remote.txt", format: .txt)
        remote.modifiedAt = Date(timeIntervalSince1970: 10)
        var local = remote
        local.fileName = "local.txt"
        local.progress = 0.75
        local.isBookmarked = true
        local.modifiedAt = Date(timeIntervalSince1970: 20)

        let recovered = CloudSyncCoordinator.bookForDownload(remote: remote, local: local, localFileAvailable: false)

        XCTAssertEqual(recovered, local)
        XCTAssertNil(CloudSyncCoordinator.bookForDownload(remote: remote, local: local, localFileAvailable: true))
        XCTAssertEqual(CloudSyncCoordinator.bookForDownload(remote: remote, local: nil, localFileAvailable: false), remote)
        remote.modifiedAt = Date(timeIntervalSince1970: 30)
        XCTAssertEqual(CloudSyncCoordinator.bookForDownload(remote: remote, local: local, localFileAvailable: true), remote)
    }

    func testDownloadRecheckDoesNotResurrectBookDeletedDuringNetworkRequest() {
        var remote = Book(title: "Book", fileName: "remote.txt", format: .txt)
        remote.modifiedAt = Date(timeIntervalSince1970: 10)
        XCTAssertNotNil(CloudSyncCoordinator.bookForDownload(remote: remote, local: nil, localFileAvailable: false))
        let deletion = BookDeletion(bookID: remote.id, deletedAt: Date(timeIntervalSince1970: 20))

        XCTAssertNil(CloudSyncCoordinator.bookForDownload(remote: remote, local: nil, localFileAvailable: false, deletion: deletion))
        var newerLocal = remote
        newerLocal.progress = 0.9
        newerLocal.modifiedAt = Date(timeIntervalSince1970: 30)
        XCTAssertEqual(CloudSyncCoordinator.bookForDownload(remote: remote, local: newerLocal, localFileAvailable: false, deletion: deletion), newerLocal)
    }

    func testUnchangedSyncedDeletionDoesNotRewriteIndex() throws {
        let root = try temporaryDirectory()
        let library = BookLibrary(storageDirectory: root)
        let deletion = BookDeletion(bookID: UUID(), deletedAt: Date(timeIntervalSince1970: 123))
        library.applySyncedDeletion(deletion)
        let fileURL = root.appendingPathComponent("deletions.json")
        let sentinel = Date(timeIntervalSince1970: 456)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: fileURL.path)

        library.applySyncedDeletion(deletion)

        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, sentinel.timeIntervalSince1970, accuracy: 0.01)
    }

    func testImportCoordinatorOpensFirstBookAndDeduplicatesQueuedRequests() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.txt")
        let second = root.appendingPathComponent("Second.txt")
        try Data("First book".utf8).write(to: first)
        try Data("Second book".utf8).write(to: second)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let coordinator = BookImportCoordinator()

        coordinator.importFiles([first, first], library: library)
        coordinator.importFiles([first, second], library: library)
        try await waitForImports(coordinator)

        XCTAssertEqual(library.books.count, 2)
        XCTAssertEqual(coordinator.bookToOpen?.title, "First")
        XCTAssertTrue(library.books.contains(where: { $0.id == coordinator.bookToOpen?.id }))
    }

    func testImportCoordinatorFailurePreservesExistingLibraryAndDoesNotOpenAReader() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Existing.txt")
        try Data("Existing book".utf8).write(to: source)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        library.importBooks(from: [source])
        let existing = library.books
        library.alertMessage = nil
        let coordinator = BookImportCoordinator()

        coordinator.importFiles([root.appendingPathComponent("Missing.epub")], library: library)
        try await waitForImports(coordinator)

        XCTAssertEqual(library.books, existing)
        XCTAssertNil(coordinator.bookToOpen)
        XCTAssertNotNil(library.alertMessage)
    }

    func testImportCoordinatorReportsMixedResultsAndAcknowledgesOnlyDurableSuccess() async throws {
        let root = try temporaryDirectory()
        let good = root.appendingPathComponent("Good.txt")
        let missing = root.appendingPathComponent("Missing.epub")
        try Data("A successfully imported book".utf8).write(to: good)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let coordinator = BookImportCoordinator()
        var acknowledged: [URL] = []

        coordinator.importFiles([good, missing], library: library) { url in
            XCTAssertEqual(library.books.count, 1)
            XCTAssertNotNil(library.fileURL(for: try XCTUnwrap(library.books.first)))
            acknowledged.append(url)
        }
        try await waitForImports(coordinator)

        XCTAssertEqual(coordinator.lastResult.importedBooks.map(\.title), ["Good"])
        XCTAssertEqual(coordinator.lastResult.rejectedFileNames, ["Missing.epub"])
        XCTAssertEqual(acknowledged, [good])
        XCTAssertEqual(coordinator.bookToOpen?.title, "Good")
    }

    func testCancelledQueuedImportCanBeRetried() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Retry.txt")
        try Data("A book that remains available for retry".utf8).write(to: source)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let coordinator = BookImportCoordinator()

        coordinator.importFiles([source], library: library)
        coordinator.cancelPendingImports()
        try await waitForImports(coordinator)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        coordinator.importFiles([source], library: library)
        try await waitForImports(coordinator)

        XCTAssertEqual(library.books.map(\.title), ["Retry"])
        XCTAssertEqual(coordinator.bookToOpen?.title, "Retry")
    }

    private func waitForImports(_ coordinator: BookImportCoordinator) async throws {
        for _ in 0..<300 {
            if !coordinator.isImporting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import did not complete")
    }

    func testFailedRemovalKeepsManagedCopyAndRestoresPreviousTombstones() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        let contents = Data("Keep the only managed copy if library persistence fails.".utf8)
        try contents.write(to: source)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        let managedURL = try XCTUnwrap(library.fileURL(for: book))
        library.applySyncedDeletion(BookDeletion(bookID: UUID(), deletedAt: Date(timeIntervalSince1970: 10)))
        let previousBooks = library.books
        let previousDeletions = library.deletedBooks
        let deletionURL = storage.appendingPathComponent("deletions.json")
        let previousDeletionData = try Data(contentsOf: deletionURL)
        let indexURL = storage.appendingPathComponent("library.json")
        let backupURL = storage.appendingPathComponent("library-backup.json")
        try FileManager.default.moveItem(at: indexURL, to: backupURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        library.alertMessage = nil

        library.remove(book)

        XCTAssertEqual(library.books, previousBooks)
        XCTAssertEqual(library.deletedBooks, previousDeletions)
        XCTAssertEqual(try Data(contentsOf: managedURL), contents)
        XCTAssertEqual(try Data(contentsOf: deletionURL), previousDeletionData)
        XCTAssertNotNil(library.alertMessage)
        // Restore the intentionally blocked index to check a real subsequent launch.
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.moveItem(at: backupURL, to: indexURL)
        let reloaded = BookLibrary(storageDirectory: storage)
        XCTAssertEqual(reloaded.books, previousBooks)
        XCTAssertEqual(reloaded.deletedBooks, previousDeletions)
        XCTAssertEqual(reloaded.data(for: book), contents)
    }

    func testSuccessfulRemovalPersistsTombstoneBeforeDeletingManagedCopy() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Book.txt")
        let contents = Data("The imported original stays where it is.".utf8)
        try contents.write(to: source)
        let storage = root.appendingPathComponent("Library")
        let library = BookLibrary(storageDirectory: storage)
        library.importBooks(from: [source])
        let book = try XCTUnwrap(library.books.first)
        // A sync can replace the managed filename while a confirmation sheet still
        // holds an earlier Book value. Removal must delete the current copy.
        XCTAssertTrue(library.applySyncedBook(book, contents: contents))
        let syncedBook = try XCTUnwrap(library.books.first)
        let managedURL = try XCTUnwrap(library.fileURL(for: syncedBook))

        library.remove(book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertFalse(library.books.contains(where: { $0.id == book.id }))
        let reloaded = BookLibrary(storageDirectory: storage)
        XCTAssertFalse(reloaded.books.contains(where: { $0.id == book.id }))
        XCTAssertEqual(reloaded.deletedBooks.first?.bookID, book.id)
    }

    func testSampleDeletionIsNotUndoneWhenPreferencesAreReset() throws {
        let root = try temporaryDirectory()
        let suite = "CloudReaderDemoTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = BookLibrary(storageDirectory: root, defaults: defaults)
        library.remove(DemoBookInstaller.makeBook(fileName: "demo-cloudreader-field-guide.txt"))
        defaults.removeObject(forKey: "cloudreader.demoBookInstalled.v1")

        library.installDemoBookIfNeeded()

        XCTAssertFalse(library.books.contains(where: { $0.id == DemoBookInstaller.bookID }))
        XCTAssertEqual(library.deletedBooks.first?.bookID, DemoBookInstaller.bookID)
        XCTAssertTrue(defaults.bool(forKey: "cloudreader.demoBookInstalled.v1"))
    }
}
