import CloudReaderCore
import CryptoKit
import Foundation
import XCTest
@testable import CloudReader

@MainActor
final class AppleSyncPipelineTests: XCTestCase {
    @MainActor
    private final class FailingSyncRepository: AppleSyncRepository {
        var books: [Book] = []
        var deletedBooks: [BookDeletion] = []
        var aiConversations: [AIConversationRecord] = []
        var deletedAIConversations: [AIConversationDeletion] = []
        func fileURL(for book: Book) -> URL? { nil }
        func data(for book: Book) -> Data? { nil }
        func applySyncedBook(_ book: Book, contents: Data) -> Bool { false }
        func applySyncedDeletion(_ deletion: BookDeletion) {}
        func applySyncedAIConversation(_ conversation: AIConversationRecord) {}
        func applySyncedAIConversationDeletion(_ deletion: AIConversationDeletion) {}
        func persistSyncSnapshot() -> Bool { false }
    }

    private actor FakeStore: RemoteBookStore {
        var objects: [String: Data] = [:]
        var failWrites = Set<String>()
        var readFailures = Set<String>()
        var onRead: (@Sendable (String) async -> Void)?
        var onWrite: (@Sendable (String) async -> Void)?
        var writes: [String] = []
        var didClose = false

        func read(_ name: String) async throws -> Data? {
            if let onRead { await onRead(name) }
            if readFailures.contains(name) { throw CocoaError(.fileReadUnknown) }
            return objects[name]
        }
        func write(_ data: Data, as name: String) async throws {
            if let onWrite { await onWrite(name) }
            if failWrites.contains(name) { throw CocoaError(.fileWriteOutOfSpace) }
            objects[name] = data
            writes.append(name)
        }
        func put(_ data: Data, as name: String) { objects[name] = data }
        func setReadFailure(_ name: String) { readFailures.insert(name) }
        func setReadGate(_ gate: @escaping @Sendable (String) async -> Void) { onRead = gate }
        func setWriteGate(_ gate: @escaping @Sendable (String) async -> Void) { onWrite = gate }
        func setWriteFailure(_ name: String) { failWrites.insert(name) }
        func clearWriteFailure(_ name: String) { failWrites.remove(name) }
        func namesWritten() -> [String] { writes }
        func close() { didClose = true }
        func isClosed() -> Bool { didClose }
    }

    private func isolatedLibrary() throws -> BookLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSyncPipeline-\(UUID().uuidString)", isDirectory: true)
        let suite = "AppleSyncPipeline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        return BookLibrary(storageDirectory: root, defaults: defaults)
    }

    private func manifest(_ books: [SyncedBook]) throws -> Data {
        var value = RemoteLibraryManifest()
        value.books = books
        return try JSONEncoder().encode(value)
    }

    private func isolatedSyncState() throws -> (AppleSyncLocalStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleSyncState-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (AppleSyncLocalStateStore(directory: directory), directory)
    }

    private func manifestWithRootFields(_ fields: [String: Any]) throws -> Data {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteLibraryManifest())) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }, options: [.sortedKeys])
    }

    func testMissingManagedCopyUsesCanonicalEqualTimeBookWinner() async throws {
        let library = try isolatedLibrary()
        let book = Book(title: "Offline", fileName: "offline.txt", format: .txt)
        var current = book
        current.progress = 0.72
        current.modifiedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(library.applySyncedBook(current, contents: Data("old".utf8)))
        let persisted = try XCTUnwrap(library.books.first(where: { $0.id == current.id }))
        try FileManager.default.removeItem(at: try XCTUnwrap(library.fileURL(for: persisted)))
        var remote = current
        remote.progress = 0.1
        let bytes = Data("restored".utf8)
        let store = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        await store.put(try manifest([SyncedBook(book: remote, sha256: Self.hash(bytes))]), as: "manifest.json")
        await store.put(bytes, as: "book-\(remote.id.uuidString).txt")

        _ = try await AppleSyncPipeline(storeFactory: { _ in store }, clock: { Date(timeIntervalSince1970: 500) }, closeStore: { value in if let fake = value as? FakeStore { await fake.close() } }, localState: syncState).run(to: .filesFolder, library: library)

        let closed = await store.isClosed()
        XCTAssertTrue(closed)
        // Equal modifiedAt records use the canonical {book, sha256} tie rule.
        XCTAssertEqual(library.books.first?.progress, 0.1)
        let restoredBook = try XCTUnwrap(library.books.first(where: { $0.id == current.id }))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(library.fileURL(for: restoredBook))), bytes)
    }

    func testCorruptRemoteObjectFailsBeforePublishingManifest() async throws {
        let library = try isolatedLibrary()
        let remote = Book(title: "Corrupt", fileName: "corrupt.txt", format: .txt)
        let store = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        await store.put(try manifest([SyncedBook(book: remote, sha256: String(repeating: "0", count: 64))]), as: "manifest.json")
        await store.put(Data("bad".utf8), as: "book-\(remote.id.uuidString).txt")

        do {
            _ = try await AppleSyncPipeline(storeFactory: { _ in store }, closeStore: { value in if let fake = value as? FakeStore { await fake.close() } }, localState: syncState).run(to: .filesFolder, library: library)
            XCTFail("Expected hash validation to fail")
        } catch { }
        let writes = await store.namesWritten()
        XCTAssertEqual(writes, [])
        let closed = await store.isClosed()
        XCTAssertTrue(closed)
        XCTAssertTrue(library.books.isEmpty)
    }

    func testMissingRemoteObjectFailsWithoutChangingLibrary() async throws {
        let library = try isolatedLibrary()
        let remote = Book(title: "Missing", fileName: "missing.txt", format: .txt)
        let store = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        await store.put(try manifest([SyncedBook(book: remote, sha256: Self.hash(Data("data".utf8)))]), as: "manifest.json")

        do {
            _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: syncState).run(to: .filesFolder, library: library)
            XCTFail("Expected missing object to fail")
        } catch { }
        XCTAssertTrue(library.books.isEmpty)
        let writes = await store.namesWritten()
        XCTAssertEqual(writes, [])
    }

    func testLocalDeletionDuringSuspendedDownloadPreventsRestore() async throws {
        let library = try isolatedLibrary()
        let remote = Book(title: "Delete me", fileName: "delete.txt", format: .txt)
        let bytes = Data("remote".utf8)
        let store = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        await store.put(try manifest([SyncedBook(book: remote, sha256: Self.hash(bytes))]), as: "manifest.json")
        await store.put(bytes, as: "book-\(remote.id.uuidString).txt")
        let gate = AsyncGate()
        await store.setReadGate { name in if name != "manifest.json" { await gate.pause() } }
        let task = Task { _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: syncState).run(to: .filesFolder, library: library) }
        await gate.waitUntilEntered()
        library.applySyncedDeletion(BookDeletion(bookID: remote.id, deletedAt: Date.distantFuture))
        await gate.open()
        _ = try await task.value
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertNotNil(library.deletedBooks.first(where: { $0.bookID == remote.id }))
    }


    func testLocalProgressEditDuringSuspendedDownloadKeepsLocalCopy() async throws {
        let library = try isolatedLibrary()
        var local = Book(title: "Edited while downloading", fileName: "edited.txt", format: .txt)
        local.modifiedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(library.applySyncedBook(local, contents: Data("local".utf8)))
        var remote = local
        remote.modifiedAt = Date(timeIntervalSince1970: 200)
        let store = FakeStore()
        let remoteBytes = Data("remote".utf8)
        await store.put(try manifest([SyncedBook(book: remote, sha256: Self.hash(remoteBytes))]), as: "manifest.json")
        await store.put(remoteBytes, as: "book-\(remote.id.uuidString).txt")
        let gate = AsyncGate()
        let (syncState, _) = try isolatedSyncState()
        await store.setReadGate { name in if name != "manifest.json" { await gate.pause() } }
        let task = Task { _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: syncState).run(to: .filesFolder, library: library) }
        await gate.waitUntilEntered()
        library.updateProgress(for: local.id, to: 0.63)
        await gate.open()
        _ = try await task.value
        XCTAssertEqual(library.books.first?.progress, 0.63)
        let latestBook = try XCTUnwrap(library.books.first(where: { $0.id == local.id }))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(library.fileURL(for: latestBook))), Data("local".utf8))
    }


    func testLocalProgressEditDuringSuspendedUploadPublishesLatestSnapshot() async throws {
        let library = try isolatedLibrary()
        let local = Book(title: "Changed while uploading", fileName: "changed.txt", format: .txt)
        XCTAssertTrue(library.applySyncedBook(local, contents: Data("local bytes".utf8)))
        let store = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        let gate = AsyncGate()
        await store.setWriteGate { name in if name != "manifest.json" { await gate.pause() } }
        let task = Task { _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: syncState).run(to: .filesFolder, library: library) }
        await gate.waitUntilEntered()
        library.updateProgress(for: local.id, to: 0.58)
        await gate.open()
        _ = try await task.value
        let optionalManifestData = try await store.read("manifest.json")
        let manifestData = try XCTUnwrap(optionalManifestData)
        let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: manifestData)
        XCTAssertEqual(manifest.books.first?.book.progress, 0.58)
    }

    func testFailedManifestPublishCanRetryAndNoBookObjectsAreUploadedForEmptyLibrary() async throws {
        let library = try isolatedLibrary()
        let store = FakeStore()
        await store.setWriteFailure("manifest.json")
        let (syncState, _) = try isolatedSyncState()
        let pipeline = AppleSyncPipeline(storeFactory: { _ in store }, clock: { Date(timeIntervalSince1970: 500) }, localState: syncState)
        do {
            _ = try await pipeline.run(to: .filesFolder, library: library)
            XCTFail("Expected first manifest publish to fail")
        } catch { }
        await store.clearWriteFailure("manifest.json")
        let counts = try await pipeline.run(to: .filesFolder, library: library)
        XCTAssertEqual(counts.books, 0)
        XCTAssertEqual(counts.conversations, 0)
        let writes = await store.namesWritten()
        XCTAssertEqual(writes, ["manifest.json"])
    }

    func testFailedLocalSyncSnapshotPreventsManifestPublish() async throws {
        let (state, _) = try isolatedSyncState()
        let store = FakeStore()
        do {
            _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: state)
                .run(to: .filesFolder, library: FailingSyncRepository())
            XCTFail("Expected local snapshot persistence failure")
        } catch { }
        let writes = await store.namesWritten()
        XCTAssertFalse(writes.contains("manifest.json"))
    }

    func testBookTiePersistsRecoveryAndPublishedManifestKeepsOnlyV1Keys() async throws {
        let library = try isolatedLibrary()
        let (state, _) = try isolatedSyncState()
        let bytes = Data("local payload".utf8)
        var local = Book(title: "Local title", fileName: "local.txt", format: .txt)
        local.modifiedAt = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(library.applySyncedBook(local, contents: bytes))
        var remoteBook = local
        remoteBook.title = "Remote title"
        let remoteBytes = Data("remote payload".utf8)
        let store = FakeStore()
        await store.put(try manifest([SyncedBook(book: remoteBook, sha256: Self.hash(remoteBytes))]), as: "manifest.json")
        await store.put(remoteBytes, as: "book-\(remoteBook.id.uuidString).txt")

        _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: state).run(to: .filesFolder, library: library)
        let candidates = try await state.loadRecoveryCandidates()
        XCTAssertTrue(candidates.contains(where: { $0.kind == "book" && $0.entityID == local.id.uuidString.uppercased() }))
        let publishedData = try await store.read("manifest.json")
        let published = try XCTUnwrap(publishedData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: published) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "updatedAt", "books", "deletions", "conversations", "conversationDeletions"]))
    }

    func testRootUnknownFieldsUnionAcrossProviderCallsAndRestart() async throws {
        let library = try isolatedLibrary()
        let (_, directory) = try isolatedSyncState()
        let firstState = AppleSyncLocalStateStore(directory: directory)
        let first = FakeStore()
        await first.put(try manifestWithRootFields(["futureA": ["nested": [1, 2]]]), as: "manifest.json")
        _ = try await AppleSyncPipeline(storeFactory: { _ in first }, localState: firstState).run(to: .filesFolder, library: library)

        let second = FakeStore()
        await second.put(try manifestWithRootFields(["futureB": false]), as: "manifest.json")
        // Construct a new pipeline and store instance to model a later provider run
        // after app restart; the local opaque snapshot carries provider A's field.
        _ = try await AppleSyncPipeline(storeFactory: { _ in second }, localState: AppleSyncLocalStateStore(directory: directory)).run(to: .webDAV, library: library)
        let publishedData = try await second.read("manifest.json")
        let published = try XCTUnwrap(publishedData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: published) as? [String: Any])
        XCTAssertEqual((object["futureA"] as? [String: Any])?["nested"] as? [Int], [1, 2])
        XCTAssertEqual(object["futureB"] as? Bool, false)
    }

    func testDeletionWinsAtEqualTimestampAndReplayDoesNotDuplicateRecovery() async throws {
        let library = try isolatedLibrary()
        let (state, _) = try isolatedSyncState()
        let bytes = Data("book".utf8)
        var book = Book(title: "Deleted", fileName: "deleted.txt", format: .txt)
        book.modifiedAt = Date(timeIntervalSinceReferenceDate: 50)
        XCTAssertTrue(library.applySyncedBook(book, contents: bytes))
        let tombstone = BookDeletion(bookID: book.id, deletedAt: book.modifiedAt)
        var remote = RemoteLibraryManifest()
        remote.deletions = [tombstone]
        let store = FakeStore()
        await store.put(try JSONEncoder().encode(remote), as: "manifest.json")
        let pipeline = AppleSyncPipeline(storeFactory: { _ in store }, localState: state)
        _ = try await pipeline.run(to: .filesFolder, library: library)
        _ = try await pipeline.run(to: .filesFolder, library: library)
        XCTAssertFalse(library.books.contains(where: { $0.id == book.id }))
        let publishedData = try await store.read("manifest.json")
        let published = try XCTUnwrap(publishedData)
        let decoded = try JSONDecoder().decode(RemoteLibraryManifest.self, from: published)
        XCTAssertTrue(decoded.books.isEmpty)
        XCTAssertEqual(decoded.deletions.first?.deletedAt, book.modifiedAt)
    }

    func testProviderOrderReplayAndRetryConvergeWithoutTransactionalClaim() async throws {
        let id = UUID()
        let times: [TimeInterval] = [31, 47, 52]
        func run(_ order: [Int], retryLast: Bool) async throws -> [TimeInterval] {
            let library = try isolatedLibrary()
            let (state, _) = try isolatedSyncState()
            let stores = (0..<3).map { _ in FakeStore() }
            for (index, store) in stores.enumerated() {
                var source = RemoteLibraryManifest()
                source.deletions = [BookDeletion(bookID: id, deletedAt: Date(timeIntervalSinceReferenceDate: times[index]))]
                await store.put(try JSONEncoder().encode(source), as: "manifest.json")
            }
            let pipeline = AppleSyncPipeline(storeFactory: { provider in
                let index = provider == .filesFolder ? 0 : provider == .webDAV ? 1 : 2
                return stores[index]
            }, localState: state)
            let providers: [CloudProviderKind] = [.filesFolder, .webDAV, .dropbox]
            var didRetry = false
            for _ in 0..<2 {
                for index in order {
                    let store = stores[index]
                    if retryLast && !didRetry && index == order.last {
                        await store.setWriteFailure("manifest.json")
                        do {
                            _ = try await pipeline.run(to: providers[index], library: library)
                            XCTFail("Expected an interrupted provider publish")
                        } catch { }
                        await store.clearWriteFailure("manifest.json")
                        didRetry = true
                    }
                    _ = try await pipeline.run(to: providers[index], library: library)
                }
            }
            var result: [TimeInterval] = []
            for store in stores {
                let maybeData = try await store.read("manifest.json")
                let data = try XCTUnwrap(maybeData)
                let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: data)
                result.append(try XCTUnwrap(manifest.deletions.first(where: { $0.bookID == id })).deletedAt.timeIntervalSinceReferenceDate)
            }
            return result
        }

        let forward = try await run([0, 1, 2], retryLast: true)
        let reverse = try await run([2, 1, 0], retryLast: false)
        XCTAssertEqual(forward, [52, 52, 52])
        XCTAssertEqual(reverse, [52, 52, 52])
    }


    func testLocalContentChangedDuringUploadIsUploadedBeforeManifestPublish() async throws {
        let library = try isolatedLibrary()
        let store = FakeStore()
        let oldBytes = Data("old content".utf8)
        let newBytes = Data("new content".utf8)
        var book = Book(title: "Changes during upload", fileName: "changing.txt", format: .txt)
        book.modifiedAt = Date(timeIntervalSinceReferenceDate: 10)
        XCTAssertTrue(library.applySyncedBook(book, contents: oldBytes))
        let gate = AsyncGate()
        let (syncState, _) = try isolatedSyncState()
        await store.setWriteGate { name in if name != "manifest.json" { await gate.pause() } }

        let task = Task { _ = try await AppleSyncPipeline(storeFactory: { _ in store }, localState: syncState).run(to: .filesFolder, library: library) }
        await gate.waitUntilEntered()
        book.title = "Edited during upload"
        book.modifiedAt = Date(timeIntervalSinceReferenceDate: 20)
        XCTAssertTrue(library.applySyncedBook(book, contents: newBytes))
        await gate.open()
        _ = try await task.value

        let remoteBytes = try await store.read("book-\(book.id.uuidString).txt")
        XCTAssertEqual(remoteBytes, newBytes)
        let maybeManifestData = try await store.read("manifest.json")
        let manifestData = try XCTUnwrap(maybeManifestData)
        let published = try JSONDecoder().decode(RemoteLibraryManifest.self, from: manifestData)
        XCTAssertEqual(published.books.first?.sha256, Self.hash(newBytes))
    }

    func testCoordinatorReportsOneFailedDestinationAndSuccessForAnother() async throws {
        let library = try isolatedLibrary()
        let suite = "AppleSyncCoordinator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set([CloudProviderKind.filesFolder.rawValue, CloudProviderKind.webDAV.rawValue], forKey: "cloudreader.providers")
        let success = FakeStore()
        let (syncState, _) = try isolatedSyncState()
        let fixedNow = Date(timeIntervalSince1970: 700)
        let coordinator = CloudSyncCoordinator(
            defaults: defaults,
            storeFactory: { provider in
                if provider == .webDAV { throw CloudSyncError.service("fixture destination offline") }
                return success
            },
            clock: { fixedNow },
            localState: syncState,
            connectionCheck: { _ in true }
        )

        await coordinator.sync(library: library)

        XCTAssertEqual(coordinator.statusMessage, "Synced to 1 of 2 destinations")
        XCTAssertTrue(coordinator.errorMessage?.contains("WebDAV: fixture destination offline") == true)
        XCTAssertEqual(coordinator.lastSync, fixedNow)
    }

    private static func hash(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
private actor AsyncGate {
    private var entered = false
    private var openGate = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !openGate { await withCheckedContinuation { openWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func open() {
        openGate = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}
