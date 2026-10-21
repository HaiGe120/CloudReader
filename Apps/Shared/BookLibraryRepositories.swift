import CloudReaderCore
import Foundation

enum LibraryCollection: Hashable {
    case books, deletions, conversations, conversationDeletions
}

struct LibrarySnapshot {
    var books: [Book] = []
    var deletions: [BookDeletion] = []
    var conversations: [AIConversationRecord] = []
    var conversationDeletions: [AIConversationDeletion] = []
}

@MainActor
protocol LibraryRepository: AnyObject {
    func load() -> LibrarySnapshot
    func save(_ snapshot: LibrarySnapshot, collections: Set<LibraryCollection>) throws
}

@MainActor
protocol ManagedContentStore: AnyObject {
    func fileURL(for safeFileName: String) -> URL?
    func booksDirectory() throws -> URL
    func removeItem(at url: URL) throws
    func contents(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func fileExists(at url: URL) -> Bool
}

@MainActor
final class JSONLibraryRepository: LibraryRepository {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func load() -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        if let data = try? Data(contentsOf: root.appendingPathComponent("library.json")),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            snapshot.books = decoded.filter { Self.isSafeFileName($0.fileName) }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("deletions.json")),
           let decoded = try? JSONDecoder().decode([BookDeletion].self, from: data) { snapshot.deletions = decoded }
        if let data = try? Data(contentsOf: root.appendingPathComponent("ai-conversations.json")),
           let decoded = try? JSONDecoder().decode([AIConversationRecord].self, from: data) { snapshot.conversations = decoded }
        if let data = try? Data(contentsOf: root.appendingPathComponent("ai-conversation-deletions.json")),
           let decoded = try? JSONDecoder().decode([AIConversationDeletion].self, from: data) { snapshot.conversationDeletions = decoded }
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot, collections: Set<LibraryCollection>) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Tombstones precede indexes; books remain the final commit point.
        if collections.contains(.deletions) {
            try encoder.encode(snapshot.deletions).write(to: root.appendingPathComponent("deletions.json"), options: .atomic)
        }
        if collections.contains(.conversationDeletions) {
            try encoder.encode(snapshot.conversationDeletions).write(to: root.appendingPathComponent("ai-conversation-deletions.json"), options: .atomic)
        }
        if collections.contains(.conversations) {
            try encoder.encode(snapshot.conversations).write(to: root.appendingPathComponent("ai-conversations.json"), options: .atomic)
        }
        if collections.contains(.books) {
            try encoder.encode(snapshot.books).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && URL(fileURLWithPath: name).lastPathComponent == name
    }
}

@MainActor
final class FileManagedContentStore: ManagedContentStore {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func fileURL(for safeFileName: String) -> URL? {
        let url = root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(safeFileName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    func booksDirectory() throws -> URL {
        let directory = root.appendingPathComponent("Books", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func removeItem(at url: URL) throws { try fileManager.removeItem(at: url) }
    func contents(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
}
