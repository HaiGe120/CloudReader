import Foundation
import XCTest
@testable import CloudReaderCore

final class BookContractTests: XCTestCase {
    func testLegacyBookDefaultsAndReferenceDatePrecision() throws {
        let json = #"{"id":"A3B54F17-90DD-41E3-A9A3-6D3A163A67D2","title":"Legacy","fileName":"legacy.txt","format":"txt","addedAt":123.125}"#.data(using: .utf8)!

        let book = try JSONDecoder().decode(Book.self, from: json)

        XCTAssertEqual(book.progress, 0)
        XCTAssertFalse(book.isBookmarked)
        XCTAssertEqual(book.modifiedAt.timeIntervalSinceReferenceDate, 123.125, accuracy: 0.000_001)
        XCTAssertNil(book.lastOpenedAt)
    }

    func testBookDateEncodingRemainsFoundationReferenceSeconds() throws {
        var book = Book(
            id: UUID(uuidString: "A3B54F17-90DD-41E3-A9A3-6D3A163A67D2")!,
            title: "Fractional date",
            fileName: "book-a3b54f17.txt",
            format: .txt
        )
        let date = Date(timeIntervalSinceReferenceDate: 321.625)
        book.addedAt = date
        book.modifiedAt = date

        let encoded = try JSONEncoder().encode(book)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["addedAt"] as? Double ?? .nan, 321.625, accuracy: 0.000_001)
        XCTAssertEqual(object["modifiedAt"] as? Double ?? .nan, 321.625, accuracy: 0.000_001)
        XCTAssertEqual(try JSONDecoder().decode(Book.self, from: encoded), book)
    }

    func testBookDeletionKeepsItsExistingKeys() throws {
        let deletion = BookDeletion(
            bookID: UUID(uuidString: "A3B54F17-90DD-41E3-A9A3-6D3A163A67D2")!,
            deletedAt: Date(timeIntervalSinceReferenceDate: 42.5)
        )

        let encoded = try JSONEncoder().encode(deletion)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["bookID", "deletedAt"])
        XCTAssertEqual(try JSONDecoder().decode(BookDeletion.self, from: encoded), deletion)
    }
}
