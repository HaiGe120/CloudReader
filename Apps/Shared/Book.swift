import Foundation

struct BookDeletion: Codable, Hashable, Identifiable {
    var bookID: UUID
    var deletedAt: Date
    var id: UUID { bookID }
}

enum BookFormat: String, Codable, CaseIterable {
    case epub
    case pdf
    case txt
    case mobi
    case azw3
    case fb2
    case cbz
    case cbr

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    var displayName: String { rawValue.uppercased() }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .cbz, .cbr: "rectangle.stack.fill"
        default: "book.closed.fill"
        }
    }

    var hasNativeReader: Bool {
        switch self {
        case .epub, .pdf, .txt: true
        case .mobi, .azw3, .fb2, .cbz, .cbr: false
        }
    }
}

struct Book: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var author: String?
    var briefDescription: String?
    var fileName: String
    var format: BookFormat
    var addedAt: Date
    var lastOpenedAt: Date?
    var progress: Double
    var isBookmarked: Bool
    var modifiedAt: Date

    init(id: UUID = UUID(), title: String, author: String? = nil, briefDescription: String? = nil, fileName: String, format: BookFormat) {
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

    private enum CodingKeys: String, CodingKey {
        case id, title, author, briefDescription, fileName, format, addedAt, lastOpenedAt, progress, isBookmarked, modifiedAt
    }

    init(from decoder: Decoder) throws {
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
    }
}
