import Combine
import CloudReaderCore
import Foundation
import PDFKit

struct BookImportResult: Sendable {
    var importedBooks: [Book] = []
    /// Source URLs aligned with `importedBooks`, in selection order.
    var importedSourceURLs: [URL] = []
    var rejectedFileNames: [String] = []
}

@MainActor
final class BookLibrary: ObservableObject {
    static let shared = BookLibrary()

    @Published private(set) var books: [Book] = []
    @Published private(set) var deletedBooks: [BookDeletion] = []
    @Published private(set) var aiConversations: [AIConversationRecord] = []
    @Published private(set) var deletedAIConversations: [AIConversationDeletion] = []
    @Published var alertMessage: String?

    private let fileManager = FileManager.default
    private let folderName = "CloudReader"
    private let storageDirectory: URL?
    private let defaults: UserDefaults
    private var resolvedStorageDirectory: URL?
    private var repository: LibraryRepository?
    private var contentStore: ManagedContentStore?
    private let injectedRepository: LibraryRepository?
    private let injectedContentStore: ManagedContentStore?
    private var progressSaveTask: Task<Void, Never>?
    private var hasPendingBookChanges = false

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard,
         repository: LibraryRepository? = nil, contentStore: ManagedContentStore? = nil) {
        self.storageDirectory = storageDirectory
        self.defaults = defaults
        self.injectedRepository = repository
        self.injectedContentStore = contentStore
        load()
    }

    var mostRecentlyRead: Book? {
        books.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // Compatibility for existing synchronous callers. Interactive import uses the async path below.
    func importBooks(from urls: [URL]) {
        let result: BookImportResult
        do {
            result = Self.prepareImports(from: urls, directory: try booksDirectory())
        } catch {
            result = BookImportResult(rejectedFileNames: urls.map(\.lastPathComponent))
        }
        _ = finishImport(result, showSuccessMessage: true)
    }

    func importBooksAsync(from urls: [URL]) async -> BookImportResult {
        let directory: URL
        do {
            directory = try booksDirectory()
        } catch {
            let result = BookImportResult(rejectedFileNames: urls.map(\.lastPathComponent))
            return finishImport(result, showSuccessMessage: false)
        }
        // File providers may need to download a file before copying it. Neither that wait nor
        // PDF/text metadata extraction should block the first reader frame or the library UI.
        let result = await Task.detached(priority: .userInitiated) {
            Self.prepareImports(from: urls, directory: directory)
        }.value
        if Task.isCancelled {
            for book in result.importedBooks {
                if let url = contentStore?.fileURL(for: book.fileName) { try? contentStore?.removeItem(at: url) }
            }
            return BookImportResult(rejectedFileNames: urls.map(\.lastPathComponent))
        }
        return finishImport(result, showSuccessMessage: false)
    }

    private func finishImport(_ prepared: BookImportResult, showSuccessMessage: Bool) -> BookImportResult {
        var result = prepared
        if !result.importedBooks.isEmpty {
            let previousBooks = books
            let previousPendingChanges = hasPendingBookChanges
            books.insert(contentsOf: result.importedBooks, at: 0)
            if !save([.books]) {
                // The inbox keeps its source until the index is durable. Roll back staged
                // records/copies so a retry cannot create phantom books or orphan files.
                books = previousBooks
                hasPendingBookChanges = previousPendingChanges
                for book in result.importedBooks {
                    if let url = fileURL(for: book) { try? contentStore?.removeItem(at: url) }
                }
                result.rejectedFileNames += result.importedBooks.map { "\($0.title).\($0.format.rawValue)" }
                result.importedBooks = []
                result.importedSourceURLs = []
                return result
            }
        }
        let count = result.importedBooks.count
        if !result.rejectedFileNames.isEmpty {
            let skipped = result.rejectedFileNames.joined(separator: ", ")
            let reason = "Skipped unsupported or unavailable files: \(skipped). Choose EPUB, PDF, TXT, MOBI, AZW3, FB2, CBZ, or CBR book files."
            alertMessage = count > 0 ? "Added \(count) \(count == 1 ? "book" : "books"). \(reason)" : reason
        } else if count > 0 && showSuccessMessage {
            alertMessage = "Added \(count) \(count == 1 ? "book" : "books") to your library."
        }
        return result
    }

    private nonisolated static func prepareImports(from urls: [URL], directory: URL) -> BookImportResult {
        var result = BookImportResult()
        var seenURLs: Set<URL> = []
        for source in urls where seenURLs.insert(source.standardizedFileURL).inserted {
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
            guard source.isFileURL, let format = BookFormat(fileExtension: source.pathExtension) else {
                result.rejectedFileNames.append(source.lastPathComponent)
                continue
            }
            let storedName = "\(UUID().uuidString).\(format.rawValue)"
            let destination = directory.appendingPathComponent(storedName)
            do {
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
                    do {
                        let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey])
                        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                        try FileManager.default.copyItem(at: readableURL, to: destination)
                    } catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                let title = source.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let description = inferredBriefDescription(from: descriptionSource(at: destination, format: format), title: title)
                result.importedBooks.append(Book(title: title, briefDescription: description, fileName: storedName, format: format))
                result.importedSourceURLs.append(source)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                result.rejectedFileNames.append(source.lastPathComponent)
            }
        }
        return result
    }

    func fileURL(for book: Book) -> URL? {
        guard Self.isSafeFileName(book.fileName) else { return nil }
        return contentStore?.fileURL(for: book.fileName)
    }

    func markOpened(_ book: Book) {
        update(book.id) { $0.lastOpenedAt = .now }
    }

    func toggleBookmark(_ book: Book) {
        update(book.id) { $0.isBookmarked.toggle() }
    }

    func updateProgress(for bookID: UUID, to progress: Double) {
        guard progress.isFinite else { return }
        let progress = min(max(progress, 0), 1)
        guard let index = books.firstIndex(where: { $0.id == bookID }), abs(books[index].progress - progress) > 0.000_000_001 else { return }
        var updated = books[index]
        updated.progress = progress
        updated.modifiedAt = .now
        books[index] = updated
        hasPendingBookChanges = true
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flushPendingChanges()
        }
    }

    // Reader dismissal and application backgrounding call this before suspension.
    func flushPendingChanges() {
        guard hasPendingBookChanges else { return }
        save([.books])
    }

    func remove(_ book: Book) {
        let currentBook = books.first(where: { $0.id == book.id }) ?? book
        let managedURL = fileURL(for: currentBook)
        let previousBooks = books
        let previousDeletions = deletedBooks
        let previousPendingChanges = hasPendingBookChanges
        let previousDeletion = deletedBooks.first(where: { $0.bookID == book.id })
        books.removeAll { $0.id == book.id }
        deletedBooks.removeAll { $0.bookID == book.id }
        var deletion = BookDeletion(bookID: book.id, deletedAt: .now)
        if let previousDeletion { deletion.preserveUnknownFields(from: previousDeletion) }
        deletedBooks.append(deletion)
        guard save([.books, .deletions]) else {
            books = previousBooks
            deletedBooks = previousDeletions
            hasPendingBookChanges = previousPendingChanges
            // Deletions are saved before the book index. Restore them if the index
            // commit failed, so a later sync cannot apply an unsuccessful removal.
            save([.deletions])
            return
        }
        // Keep the only managed copy until both metadata files have been saved.
        if let managedURL { try? contentStore?.removeItem(at: managedURL) }
    }

    func data(for book: Book) -> Data? {
        guard let url = fileURL(for: book) else { return nil }
        return try? contentStore?.contents(at: url)
    }

    func readingContext(for book: Book, maximumCharacters: Int = 18_000) -> String? {
        guard maximumCharacters > 0, let url = fileURL(for: book) else { return nil }
        let contents: String?
        switch book.format {
        case .txt:
            let maximumBytes = maximumCharacters > (Int.max - 4) / 4 ? Int.max : maximumCharacters * 4 + 4
            contents = Self.textPrefix(at: url, maximumBytes: maximumBytes)
        case .pdf:
            contents = PDFDocument(url: url)?.string
        case .epub, .mobi, .azw3, .fb2, .cbz, .cbr:
            contents = nil
        }
        guard let contents, !contents.isEmpty else { return nil }
        if contents.count <= maximumCharacters { return contents }
        return String(contents.prefix(maximumCharacters)) + "\n\n[Context shortened to fit the AI request. The source book stays on this device.]"
    }

    func briefDescription(for book: Book) -> String? {
        if let savedDescription = book.briefDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !savedDescription.isEmpty {
            return savedDescription
        }
        guard let url = fileURL(for: book) else { return nil }
        return Self.inferredBriefDescription(from: Self.descriptionSource(at: url, format: book.format), title: book.title)
    }

    func installDemoBookIfNeeded() {
        let seedKey = "cloudreader.demoBookInstalled.v1"
        // A restored preferences store must not resurrect a deliberately deleted sample.
        if deletedBooks.contains(where: { $0.bookID == DemoBookInstaller.bookID }) {
            defaults.set(true, forKey: seedKey)
            return
        }
        let demoIndex = books.firstIndex(where: { $0.id == DemoBookInstaller.bookID })
        if let demoIndex, books[demoIndex].briefDescription == nil {
            books[demoIndex].briefDescription = DemoBookInstaller.briefDescription
            books[demoIndex].modifiedAt = .now
            save([.books])
        }
        guard (!defaults.bool(forKey: seedKey) || demoIndex.map({ fileURL(for: books[$0]) == nil }) == true),
              let source = Bundle.main.url(forResource: "CloudReader_Field_Guide", withExtension: "txt") else { return }
        do {
            let fileName = demoIndex.map { books[$0].fileName } ?? "demo-cloudreader-field-guide.txt"
            guard Self.isSafeFileName(fileName) else { return }
            let directory = try booksDirectory()
            let destination = directory.appendingPathComponent(fileName)
            if !(contentStore?.fileExists(at: destination) ?? fileManager.fileExists(atPath: destination.path)) {
                try fileManager.copyItem(at: source, to: destination)
            }
            if demoIndex == nil {
                books.append(DemoBookInstaller.makeBook(fileName: fileName))
                guard save([.books]) else { return }
            }
            defaults.set(true, forKey: seedKey)
        } catch {
            alertMessage = "CloudReader couldn't install its sample book. Check the available storage on this device."
        }
    }

    @discardableResult
    func applySyncedBook(_ book: Book, contents: Data) -> Bool {
        let previousBooks = books
        let previousDeletions = deletedBooks
        let previousPendingChanges = hasPendingBookChanges
        let previousURL = books.first(where: { $0.id == book.id }).flatMap { fileURL(for: $0) }
        do {
            guard let contentStore else { throw ManagedContentStoreUnavailable() }
            var localBook = book
            if let previous = books.first(where: { $0.id == book.id }) {
                localBook.preserveUnknownFields(from: previous)
            }
            localBook.fileName = "sync-\(book.id.uuidString).\(book.format.rawValue)"
            let directory = try booksDirectory()
            let destination = directory.appendingPathComponent(localBook.fileName)
            let destinationExisted = contentStore.fileExists(at: destination)
            try contentStore.write(contents, to: destination)
            if let index = books.firstIndex(where: { $0.id == localBook.id }) {
                books[index] = localBook
            } else {
                books.append(localBook)
            }
            deletedBooks.removeAll { $0.bookID == localBook.id }
            guard save([.books, .deletions]) else {
                books = previousBooks
                deletedBooks = previousDeletions
                hasPendingBookChanges = previousPendingChanges
                if !destinationExisted { try? contentStore.removeItem(at: destination) }
                return false
            }
            if let previousURL, previousURL != destination { try? contentStore.removeItem(at: previousURL) }
            return true
        } catch {
            alertMessage = "CloudReader couldn't download a synced book. Check the available storage on this device."
            return false
        }
    }

    func applySyncedDeletion(_ deletion: BookDeletion) {
        let previousBooks = books
        let previousDeletions = deletedBooks
        let previousPendingChanges = hasPendingBookChanges
        var changed: Set<LibraryCollection> = []
        let bookToRemove = books.first(where: { $0.id == deletion.bookID }).flatMap { book in
            book.modifiedAt <= deletion.deletedAt ? book : nil
        }
        if bookToRemove != nil {
            books.removeAll { $0.id == deletion.bookID }
            changed.insert(.books)
        }
        if let index = deletedBooks.firstIndex(where: { $0.bookID == deletion.bookID }) {
            if deletedBooks[index].deletedAt < deletion.deletedAt {
                var replacement = deletion
                replacement.preserveUnknownFields(from: deletedBooks[index])
                deletedBooks[index] = replacement
                changed.insert(.deletions)
            }
        } else {
            deletedBooks.append(deletion)
            changed.insert(.deletions)
        }
        if !changed.isEmpty && !save(changed) {
            books = previousBooks
            deletedBooks = previousDeletions
            hasPendingBookChanges = previousPendingChanges
            if changed.contains(.deletions) { _ = save([.deletions]) }
            return
        }
        // Keep the managed bytes until the updated library index is durable. A failed
        // repository write must not leave a still-indexed book with no local copy.
        if let bookToRemove, let url = fileURL(for: bookToRemove) {
            try? contentStore?.removeItem(at: url)
        }
    }

    /// Force all collections to disk before sync publishes a manifest derived from them.
    /// Progress edits are debounced during reading, so a sync boundary must flush them.
    @discardableResult
    func persistSyncSnapshot() -> Bool {
        save([.books, .deletions, .conversations, .conversationDeletions])
    }

    func saveAIConversation(_ conversation: AIConversationRecord) {
        guard !conversation.messages.isEmpty else { return }
        var saved = conversation
        if let existing = aiConversations.first(where: { $0.id == saved.id }) {
            saved.createdAt = existing.createdAt
            saved.preserveUnknownFields(from: existing)
        }
        saved.modifiedAt = .now
        if let firstQuestion = saved.messages.first(where: { $0.role == .user })?.text {
            saved.title = AIConversationRecord.suggestedTitle(for: firstQuestion)
        }
        if let index = aiConversations.firstIndex(where: { $0.id == saved.id }) {
            aiConversations[index] = saved
        } else {
            aiConversations.append(saved)
        }
        deletedAIConversations.removeAll { $0.conversationID == saved.id }
        save([.conversations, .conversationDeletions])
    }

    func removeAIConversation(_ conversation: AIConversationRecord) {
        let previousDeletion = deletedAIConversations.first(where: { $0.conversationID == conversation.id })
        aiConversations.removeAll { $0.id == conversation.id }
        deletedAIConversations.removeAll { $0.conversationID == conversation.id }
        var deletion = AIConversationDeletion(conversationID: conversation.id, deletedAt: .now)
        if let previousDeletion { deletion.preserveUnknownFields(from: previousDeletion) }
        deletedAIConversations.append(deletion)
        save([.conversations, .conversationDeletions])
    }

    func applySyncedAIConversation(_ conversation: AIConversationRecord) {
        var merged = conversation
        if let local = aiConversations.first(where: { $0.id == conversation.id }) {
            merged = local.merging(conversation)
            if local == merged { return }
        }
        if let deletion = deletedAIConversations.first(where: { $0.conversationID == merged.id }), deletion.deletedAt >= merged.modifiedAt {
            return
        }
        if let index = aiConversations.firstIndex(where: { $0.id == merged.id }) {
            aiConversations[index] = merged
        } else {
            aiConversations.append(merged)
        }
        deletedAIConversations.removeAll { $0.conversationID == merged.id && $0.deletedAt < merged.modifiedAt }
        save([.conversations, .conversationDeletions])
    }

    func applySyncedAIConversationDeletion(_ deletion: AIConversationDeletion) {
        var changed: Set<LibraryCollection> = []
        if let conversation = aiConversations.first(where: { $0.id == deletion.conversationID }), conversation.modifiedAt <= deletion.deletedAt {
            aiConversations.removeAll { $0.id == deletion.conversationID }
            changed.insert(.conversations)
        }
        if let index = deletedAIConversations.firstIndex(where: { $0.conversationID == deletion.conversationID }) {
            if deletedAIConversations[index].deletedAt < deletion.deletedAt {
                var replacement = deletion
                replacement.preserveUnknownFields(from: deletedAIConversations[index])
                deletedAIConversations[index] = replacement
                changed.insert(.conversationDeletions)
            }
        } else {
            deletedAIConversations.append(deletion)
            changed.insert(.conversationDeletions)
        }
        if !changed.isEmpty { save(changed) }
    }

    private func update(_ id: UUID, change: (inout Book) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
        books[index].modifiedAt = .now
        save([.books])
    }

    private func load() {
        guard let root = try? applicationSupportDirectory() else { return }
        contentStore = injectedContentStore ?? FileManagedContentStore(root: root)
        repository = injectedRepository ?? JSONLibraryRepository(root: root)
        let snapshot = repository?.load() ?? LibrarySnapshot()
        books = snapshot.books
        deletedBooks = snapshot.deletions
        aiConversations = snapshot.conversations
        deletedAIConversations = snapshot.conversationDeletions
    }

    @discardableResult
    private func save(_ collections: Set<LibraryCollection>) -> Bool {
        if collections.contains(.books) {
            progressSaveTask?.cancel()
            progressSaveTask = nil
        }
        do {
            guard let repository else { throw LibraryRepositoryUnavailable() }
            try repository.save(LibrarySnapshot(books: books, deletions: deletedBooks, conversations: aiConversations,
                                                conversationDeletions: deletedAIConversations), collections: collections)
            if collections.contains(.books) { hasPendingBookChanges = false }
            return true
        } catch {
            if collections.contains(.books) { hasPendingBookChanges = true }
            alertMessage = "CloudReader couldn't save your library. Check the available storage on this device."
            return false
        }
    }

    private func booksDirectory() throws -> URL {
        if contentStore == nil {
            let root = try applicationSupportDirectory()
            contentStore = injectedContentStore ?? FileManagedContentStore(root: root)
        }
        return try contentStore!.booksDirectory()
    }

    private func applicationSupportDirectory() throws -> URL {
        if let resolvedStorageDirectory { return resolvedStorageDirectory }
        if let storageDirectory {
            resolvedStorageDirectory = storageDirectory
            return storageDirectory
        }
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent(folderName, isDirectory: true)
        resolvedStorageDirectory = root
        return root
    }

    private nonisolated static func descriptionSource(at url: URL, format: BookFormat) -> String? {
        switch format {
        case .txt:
            return textPrefix(at: url, maximumBytes: 65_536)
        case .pdf:
            guard let document = PDFDocument(url: url) else { return nil }
            return (0..<min(document.pageCount, 3))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
        case .epub, .mobi, .azw3, .fb2, .cbz, .cbr:
            return nil
        }
    }

    private nonisolated static func inferredBriefDescription(from source: String?, title: String) -> String? {
        guard let source else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count > 28, line.lowercased() != normalizedTitle else { return false }
                let lowered = line.lowercased()
                return !lowered.hasPrefix("chapter ")
                    && !lowered.hasPrefix("copyright")
                    && !lowered.hasPrefix("isbn")
                    && !lowered.hasPrefix("all rights reserved")
            }
        guard !lines.isEmpty else { return nil }

        let opening = lines.prefix(8).joined(separator: " ")
        let limit = 360
        guard opening.count > limit else { return opening }
        let prefix = String(opening.prefix(limit))
        if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > 250 {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private nonisolated static func textPrefix(at url: URL, maximumBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes), !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // A bounded read can end inside a UTF-8 character; decoding keeps the preceding text.
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && URL(fileURLWithPath: name).lastPathComponent == name
    }
}

private struct LibraryRepositoryUnavailable: Error {}
private struct ManagedContentStoreUnavailable: Error {}
