import Foundation

public struct AIConversationMessage: Identifiable, Codable, Hashable, Sendable {
    public enum Role: Codable, Hashable, Sendable {
        case user
        case assistant
        case unknown(String)

        public var rawValue: String {
            switch self {
            case .user: "user"
            case .assistant: "assistant"
            case .unknown(let value): value
            }
        }

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            switch value {
            case "user": self = .user
            case "assistant": self = .assistant
            default: self = .unknown(value)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            try value.encode(rawValue)
        }
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    var unknownFields = OpaqueJSONFields()

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    public static func user(_ text: String) -> AIConversationMessage { AIConversationMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> AIConversationMessage { AIConversationMessage(role: .assistant, text: text) }

    public mutating func preserveUnknownFields(from previous: AIConversationMessage) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, role, text, createdAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encode(text, forKey: .text)
        try values.encode(createdAt, forKey: .createdAt)
        try unknownFields.encode(to: encoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }
}

public struct AIConversationRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var messages: [AIConversationMessage]
    public var bookID: UUID?
    public var bookTitle: String?
    public var bookDescription: String?
    public var selectedText: String?
    public var bookContext: String?
    public var contextDescription: String?
    public var includeBookContext: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    var unknownFields = OpaqueJSONFields()

    public init(
        id: UUID = UUID(),
        title: String = "New conversation",
        messages: [AIConversationMessage] = [],
        bookID: UUID? = nil,
        bookTitle: String? = nil,
        bookDescription: String? = nil,
        selectedText: String? = nil,
        bookContext: String? = nil,
        contextDescription: String? = nil,
        includeBookContext: Bool = false,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.bookDescription = bookDescription
        self.selectedText = selectedText
        self.bookContext = bookContext
        self.contextDescription = contextDescription
        self.includeBookContext = includeBookContext
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public func merging(_ other: AIConversationRecord) -> AIConversationRecord {
        let lhs = RemoteLibraryManifest(); var left = lhs; left.conversations = [self]
        var right = lhs; right.conversations = [other]
        return left.merging(right).manifest.conversations.first ?? self
    }

    private static func canonicalConversation(_ value: AIConversationRecord) -> Data {
        var copy = value
        copy.messages = []
        return canonicalData(copy)
    }

    private static func canonicalMessage(_ value: AIConversationMessage) -> Data { canonicalData(value) }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    public mutating func preserveUnknownFields(from previous: AIConversationRecord) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
        let previousMessages = Dictionary(previous.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for index in messages.indices {
            if let previousMessage = previousMessages[messages[index].id] {
                messages[index].preserveUnknownFields(from: previousMessage)
            }
        }
    }

    public static func suggestedTitle(for firstQuestion: String) -> String {
        let singleLine = firstQuestion
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 64 else { return singleLine.isEmpty ? "New conversation" : singleLine }
        return String(singleLine.prefix(61)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, messages, bookID, bookTitle, bookDescription, selectedText
        case bookContext, contextDescription, includeBookContext, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        messages = try values.decode([AIConversationMessage].self, forKey: .messages)
        bookID = try values.decodeIfPresent(UUID.self, forKey: .bookID)
        bookTitle = try values.decodeIfPresent(String.self, forKey: .bookTitle)
        bookDescription = try values.decodeIfPresent(String.self, forKey: .bookDescription)
        selectedText = try values.decodeIfPresent(String.self, forKey: .selectedText)
        bookContext = try values.decodeIfPresent(String.self, forKey: .bookContext)
        contextDescription = try values.decodeIfPresent(String.self, forKey: .contextDescription)
        includeBookContext = try values.decodeIfPresent(Bool.self, forKey: .includeBookContext) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(messages, forKey: .messages)
        try values.encodeIfPresent(bookID, forKey: .bookID)
        try values.encodeIfPresent(bookTitle, forKey: .bookTitle)
        try values.encodeIfPresent(bookDescription, forKey: .bookDescription)
        try values.encodeIfPresent(selectedText, forKey: .selectedText)
        try values.encodeIfPresent(bookContext, forKey: .bookContext)
        try values.encodeIfPresent(contextDescription, forKey: .contextDescription)
        try values.encode(includeBookContext, forKey: .includeBookContext)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try unknownFields.encode(to: encoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }
}

public struct AIConversationDeletion: Codable, Hashable, Identifiable, Sendable {
    public var conversationID: UUID
    public var deletedAt: Date
    public var id: UUID { conversationID }
    var unknownFields = OpaqueJSONFields()

    public init(conversationID: UUID, deletedAt: Date) {
        self.conversationID = conversationID
        self.deletedAt = deletedAt
    }

    public mutating func preserveUnknownFields(from previous: AIConversationDeletion) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    private enum CodingKeys: String, CodingKey { case conversationID, deletedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        deletedAt = try values.decode(Date.self, forKey: .deletedAt)
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: ["conversationID", "deletedAt"])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(deletedAt, forKey: .deletedAt)
        try unknownFields.encode(to: encoder, excluding: ["conversationID", "deletedAt"])
    }
}
