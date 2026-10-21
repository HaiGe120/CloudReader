import Foundation

public struct SyncedBook: Codable, Sendable {
    public var book: Book
    public var sha256: String
    var unknownFields = OpaqueJSONFields()

    public init(book: Book, sha256: String) {
        self.book = book
        self.sha256 = sha256
    }

    public mutating func preserveUnknownFields(from previous: SyncedBook) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    private enum CodingKeys: String, CodingKey { case book, sha256 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        book = try values.decode(Book.self, forKey: .book)
        sha256 = try values.decode(String.self, forKey: .sha256)
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: ["book", "sha256"])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(book, forKey: .book)
        try values.encode(sha256, forKey: .sha256)
        try unknownFields.encode(to: encoder, excluding: ["book", "sha256"])
    }
}

public struct RemoteLibraryManifest: Codable, Sendable {
    public var schemaVersion = 1
    public var updatedAt = Date()
    public var books: [SyncedBook] = []
    public var deletions: [BookDeletion] = []
    public var conversations: [AIConversationRecord] = []
    public var conversationDeletions: [AIConversationDeletion] = []
    var unknownFields = OpaqueJSONFields()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, updatedAt, books, deletions, conversations, conversationDeletions
    }

    public init() {}

    public mutating func preserveUnknownFields(from previous: RemoteLibraryManifest) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported schema version \(schemaVersion)")
        }
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        books = try values.decodeIfPresent([SyncedBook].self, forKey: .books) ?? []
        deletions = try values.decodeIfPresent([BookDeletion].self, forKey: .deletions) ?? []
        conversations = try values.decodeIfPresent([AIConversationRecord].self, forKey: .conversations) ?? []
        conversationDeletions = try values.decodeIfPresent([AIConversationDeletion].self, forKey: .conversationDeletions) ?? []
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == 1 else {
            throw EncodingError.invalidValue(schemaVersion, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported schema version \(schemaVersion)"
            ))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(books, forKey: .books)
        try values.encode(deletions, forKey: .deletions)
        try values.encode(conversations, forKey: .conversations)
        try values.encode(conversationDeletions, forKey: .conversationDeletions)
        try unknownFields.encode(to: encoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }
}

/// Validates remote wire data before a sync adapter applies any part of it.
/// Local persistence intentionally continues to decode legacy records without
/// applying these stricter remote-input checks.
public enum RemoteManifestValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidTimestamp
    case invalidDigest
    case unsafeFileName
    case invalidProgress
}

public extension RemoteLibraryManifest {
    func validateForRemoteSync() throws {
        guard schemaVersion == 1 else { throw RemoteManifestValidationError.unsupportedVersion(schemaVersion) }
        func timestampIsFinite(_ date: Date) -> Bool {
            date.timeIntervalSinceReferenceDate.isFinite
        }
        guard timestampIsFinite(updatedAt) else { throw RemoteManifestValidationError.invalidTimestamp }
        for item in books {
            guard item.sha256.utf8.count == 64,
                  item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RemoteManifestValidationError.invalidDigest
            }
            let name = item.book.fileName
            let safeCharacters = name.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 45].contains($0)
            }
            guard !name.isEmpty, name.utf8.count <= 160, safeCharacters, !name.contains("..") else {
                throw RemoteManifestValidationError.unsafeFileName
            }
            guard (0...1).contains(item.book.progress), item.book.progress.isFinite else {
                throw RemoteManifestValidationError.invalidProgress
            }
            guard timestampIsFinite(item.book.addedAt),
                  item.book.lastOpenedAt.map(timestampIsFinite) ?? true,
                  timestampIsFinite(item.book.modifiedAt) else {
                throw RemoteManifestValidationError.invalidTimestamp
            }
        }
        guard deletions.allSatisfy({ timestampIsFinite($0.deletedAt) }),
              conversationDeletions.allSatisfy({ timestampIsFinite($0.deletedAt) }),
              conversations.allSatisfy({ conversation in
                  timestampIsFinite(conversation.createdAt) && timestampIsFinite(conversation.modifiedAt) &&
                      conversation.messages.allSatisfy { timestampIsFinite($0.createdAt) }
              }) else {
            throw RemoteManifestValidationError.invalidTimestamp
        }
    }
}
