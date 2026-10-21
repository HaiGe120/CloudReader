import CloudReaderCore
import CryptoKit
import Foundation

@MainActor
protocol AppleSyncRepository: AnyObject {
    var books: [Book] { get }
    var deletedBooks: [BookDeletion] { get }
    var aiConversations: [AIConversationRecord] { get }
    var deletedAIConversations: [AIConversationDeletion] { get }
    func fileURL(for book: Book) -> URL?
    func data(for book: Book) -> Data?
    @discardableResult func applySyncedBook(_ book: Book, contents: Data) -> Bool
    func applySyncedDeletion(_ deletion: BookDeletion)
    func applySyncedAIConversation(_ conversation: AIConversationRecord)
    func applySyncedAIConversationDeletion(_ deletion: AIConversationDeletion)
    @discardableResult func persistSyncSnapshot() -> Bool
}

extension BookLibrary: AppleSyncRepository {}

@MainActor
final class AppleSyncPipeline {
    typealias StoreFactory = (CloudProviderKind) throws -> any RemoteBookStore
    typealias Clock = () -> Date
    typealias StoreCloser = (any RemoteBookStore) async -> Void

    private let storeFactory: StoreFactory
    private let clock: Clock
    private let closeStore: StoreCloser
    private let localState: AppleSyncLocalStateStore

    init(storeFactory: @escaping StoreFactory = { try RemoteStoreFactory.make($0) },
         clock: @escaping Clock = Date.init,
         closeStore: @escaping StoreCloser = { store in
             if let sftp = store as? SFTPStore { await sftp.closeConnection() }
         },
         localState: AppleSyncLocalStateStore = AppleSyncLocalStateStore()) {
        self.storeFactory = storeFactory
        self.clock = clock
        self.closeStore = closeStore
        self.localState = localState
    }

    func run(to provider: CloudProviderKind, library: any AppleSyncRepository) async throws -> (books: Int, conversations: Int) {
        let store = try storeFactory(provider)
        do {
            let result = try await run(using: store, to: provider, library: library)
            await closeStore(store)
            return result
        } catch {
            await closeStore(store)
            throw error
        }
    }

    private func run(using store: any RemoteBookStore, to provider: CloudProviderKind, library: any AppleSyncRepository) async throws -> (books: Int, conversations: Int) {
        let remoteData: Data?
        do { remoteData = try await store.read("manifest.json") }
        catch { throw CloudSyncError.service("Could not read the sync index: \(error.localizedDescription)") }
        var remote = try remoteData.map { try JSONDecoder().decode(RemoteLibraryManifest.self, from: $0) } ?? RemoteLibraryManifest()
        guard remote.schemaVersion == 1 else { throw CloudSyncError.malformedResponse }
        do { try remote.validateForRemoteSync() }
        catch { throw CloudSyncError.malformedResponse }

        // Root opaque fields have no home in v1 local library records, so carry them
        // through the app-private snapshot between provider runs and process restarts.
        do {
            let persisted = try await localState.loadRootOpaqueManifestFields()
            let rootMerge = remote.mergingRootUnknownFields(persisted)
            remote = rootMerge.manifest
            try await localState.saveRootOpaqueManifestFields(remote.rootUnknownFields)
            try await localState.appendRecoveryCandidates(rootMerge.recoveryCandidates)
        } catch { throw CloudSyncError.service("Could not save sync recovery state: \(error.localizedDescription)") }

        let initial = try await merge(remote: remote, library: library)
        try await persist(initial.recoveryCandidates)
        let initialManifest = initial.manifest
        // Applying merged tombstones first enforces deletion-wins on equal timestamps.
        for deletion in initialManifest.deletions { library.applySyncedDeletion(deletion) }
        for deletion in initialManifest.conversationDeletions { library.applySyncedAIConversationDeletion(deletion) }
        for conversation in initialManifest.conversations { library.applySyncedAIConversation(conversation) }

        // Download only when policy selected bytes not present locally. Recheck the
        // local book after suspension so a user edit/delete cannot be overwritten.
        for item in initialManifest.books {
            let current = library.books.first(where: { $0.id == item.book.id })
            let currentBytes = current.flatMap { library.data(for: $0) }
            if let currentBytes, digest(currentBytes) == item.sha256 {
                if current == item.book { continue }
                guard library.applySyncedBook(item.book, contents: currentBytes) else {
                    throw CloudSyncError.service("Could not save '\(item.book.title)' on this device. Its cloud index was left unchanged.")
                }
                continue
            }
            // A primary candidate selected from the remote manifest must agree with
            // the provider's single v1 object at this ID-based name.
            guard remote.books.contains(where: { $0.book.id == item.book.id && $0.sha256 == item.sha256 }) else { continue }
            let bytes: Data?
            do { bytes = try await store.read(objectName(for: item.book)) }
            catch { throw CloudSyncError.service("Could not download '\(item.book.title)': \(error.localizedDescription)") }
            guard let bytes else {
                throw CloudSyncError.service("\(provider.title) is missing the book file for '\(item.book.title)'. Its index was left unchanged.")
            }
            guard digest(bytes) == item.sha256 else {
                throw CloudSyncError.service("\(provider.title) has a damaged copy of '\(item.book.title)'. Its index was left unchanged.")
            }
            if library.deletedBooks.first(where: { $0.bookID == item.book.id }).map({ $0.deletedAt >= item.book.modifiedAt }) == true {
                continue
            }
            let latest = library.books.first(where: { $0.id == item.book.id })
            let latestBytes = latest.flatMap { library.data(for: $0) }
            let unchanged = latest == current && latestBytes.map(digest) == currentBytes.map(digest)
            guard unchanged else { continue }
            guard library.applySyncedBook(item.book, contents: bytes) else {
                throw CloudSyncError.service("Could not save '\(item.book.title)' on this device. Its cloud index was left unchanged.")
            }
        }

        // Uploads suspend. Resnapshot after every pass so a content edit during an
        // upload gets its own transfer before any manifest can reference its hash.
        var availableHashes = Dictionary(remote.books.map { ($0.book.id, $0.sha256) }, uniquingKeysWith: { _, newest in newest })
        var publishMerge: RemoteLibraryManifest?
        for _ in 0..<3 {
            var pass = try await merge(remote: remote, library: library)
            try await persist(pass.recoveryCandidates)
            for deletion in pass.manifest.deletions { library.applySyncedDeletion(deletion) }
            for deletion in pass.manifest.conversationDeletions { library.applySyncedAIConversationDeletion(deletion) }
            for conversation in pass.manifest.conversations { library.applySyncedAIConversation(conversation) }

            let snapshot = localBooks(library)
            for item in pass.manifest.books {
                guard let local = snapshot.first(where: { $0.book.id == item.book.id }), local.sha256 == item.sha256,
                      availableHashes[local.book.id] != local.sha256,
                      let bytes = library.data(for: local.book), digest(bytes) == local.sha256 else { continue }
                do { try await store.write(bytes, as: objectName(for: local.book)) }
                catch { throw CloudSyncError.service("Could not upload '\(local.book.title)': \(error.localizedDescription)") }
                availableHashes[local.book.id] = local.sha256
            }

            pass = try await merge(remote: remote, library: library)
            try await persist(pass.recoveryCandidates)
            let freshSnapshot = localBooks(library)
            let hasUnuploadedSelectedContent = pass.manifest.books.contains { item in
                guard let local = freshSnapshot.first(where: { $0.book.id == item.book.id }), local.sha256 == item.sha256 else { return false }
                return availableHashes[local.book.id] != local.sha256
            }
            if !hasUnuploadedSelectedContent {
                publishMerge = pass.manifest
                break
            }
        }
        guard var latestMerge = publishMerge else {
            throw CloudSyncError.service("The library kept changing during sync. The cloud index was left unchanged; try again.")
        }
        for deletion in latestMerge.deletions { library.applySyncedDeletion(deletion) }
        for deletion in latestMerge.conversationDeletions { library.applySyncedAIConversationDeletion(deletion) }
        for conversation in latestMerge.conversations { library.applySyncedAIConversation(conversation) }
        guard library.persistSyncSnapshot() else {
            throw CloudSyncError.service("Could not save the merged library on this device. Its cloud index was left unchanged.")
        }
        latestMerge.updatedAt = clock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try await store.write(encoder.encode(latestMerge), as: "manifest.json") }
        catch { throw CloudSyncError.service("Could not update the sync index: \(error.localizedDescription)") }
        return (latestMerge.books.count, latestMerge.conversations.count)
    }

    private func merge(remote: RemoteLibraryManifest, library: any AppleSyncRepository) async throws -> RemoteManifestMergeResult {
        var local = RemoteLibraryManifest()
        local.books = localBooks(library)
        local.deletions = library.deletedBooks
        local.conversations = library.aiConversations
        local.conversationDeletions = library.deletedAIConversations
        let result = remote.merging(local)
        let persisted = try await localState.loadRootOpaqueManifestFields()
        let root = result.manifest.mergingRootUnknownFields(persisted)
        try await localState.saveRootOpaqueManifestFields(root.manifest.rootUnknownFields)
        try await persist(root.recoveryCandidates)
        return RemoteManifestMergeResult(manifest: root.manifest,
                                         recoveryCandidates: result.recoveryCandidates + root.recoveryCandidates)
    }

    private func localBooks(_ library: any AppleSyncRepository) -> [SyncedBook] {
        library.books.compactMap { book in
            guard let bytes = library.data(for: book) else { return nil }
            return SyncedBook(book: book, sha256: digest(bytes))
        }
    }

    private func persist(_ candidates: [SyncRecoveryCandidate]) async throws {
        try await localState.appendRecoveryCandidates(candidates)
    }

    private func objectName(for book: Book) -> String { "book-\(book.id.uuidString).\(book.format.rawValue)" }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
