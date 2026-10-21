import Foundation

public struct BookDeletion: Codable, Hashable, Identifiable, Sendable {
    public var bookID: UUID
    public var deletedAt: Date
    public var id: UUID { bookID }
    var unknownFields = OpaqueJSONFields()

    public init(bookID: UUID, deletedAt: Date) {
        self.bookID = bookID
        self.deletedAt = deletedAt
    }

    public mutating func preserveUnknownFields(from previous: BookDeletion) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    private enum CodingKeys: String, CodingKey { case bookID, deletedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try values.decode(UUID.self, forKey: .bookID)
        deletedAt = try values.decode(Date.self, forKey: .deletedAt)
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: ["bookID", "deletedAt"])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bookID, forKey: .bookID)
        try values.encode(deletedAt, forKey: .deletedAt)
        try unknownFields.encode(to: encoder, excluding: ["bookID", "deletedAt"])
    }
}

public enum BookFormat: String, Codable, CaseIterable, Sendable {
    case epub
    case pdf
    case txt
    case mobi
    case azw3
    case fb2
    case cbz
    case cbr

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    public var displayName: String { rawValue.uppercased() }

    public var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .cbz, .cbr: "rectangle.stack.fill"
        default: "book.closed.fill"
        }
    }

    public var hasNativeReader: Bool {
        switch self {
        case .epub, .pdf, .txt: true
        case .mobi, .azw3, .fb2, .cbz, .cbr: false
        }
    }
}

public struct Book: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var author: String?
    public var briefDescription: String?
    public var fileName: String
    public var format: BookFormat
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var progress: Double
    public var isBookmarked: Bool
    public var modifiedAt: Date
    var unknownFields = OpaqueJSONFields()

    public init(id: UUID = UUID(), title: String, author: String? = nil, briefDescription: String? = nil, fileName: String, format: BookFormat) {
        self.id = id
        self.title = title
        self.author = author
        self.briefDescription = briefDescription
        self.fileName = fileName
        self.format = format
        self.addedAt = .now
        self.lastOpenedAt = nil
        self.progress = 0
        self.isBookmarked = false
        self.modifiedAt = .now
    }

    public mutating func preserveUnknownFields(from previous: Book) {
        unknownFields.keepMissingFields(from: previous.unknownFields)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, author, briefDescription, fileName, format, addedAt, lastOpenedAt, progress, isBookmarked, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        briefDescription = try values.decodeIfPresent(String.self, forKey: .briefDescription)
        fileName = try values.decode(String.self, forKey: .fileName)
        format = try values.decode(BookFormat.self, forKey: .format)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        isBookmarked = try values.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? lastOpenedAt ?? addedAt
        unknownFields = try OpaqueJSONFields.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(author, forKey: .author)
        try values.encodeIfPresent(briefDescription, forKey: .briefDescription)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(format, forKey: .format)
        try values.encode(addedAt, forKey: .addedAt)
        try values.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try values.encode(progress, forKey: .progress)
        try values.encode(isBookmarked, forKey: .isBookmarked)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try unknownFields.encode(to: encoder, excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }
}
