import Foundation
import XCTest
@testable import CloudReaderCore

final class UnknownPreservationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../Contracts/v1/fixtures/\(name)")
            .standardizedFileURL
        return try Data(contentsOf: url)
    }

    func testSharedNestedUnknownFixtureRoundTripsWithoutChangingJSONValues() throws {
        let fixtureData = try fixture("nested-unknown.json")
        let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: fixtureData)
        let roundTripped = try JSONEncoder().encode(manifest)

        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let roundTrippedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTripped) as? [String: Any])

        // Existing model defaults may add known keys when encoding. Compare every unknown
        // extension subtree exactly, including Foundation's null/bool/number representations.
        func unknownValues(_ root: [String: Any]) throws -> [String: Any] {
            let entry = try XCTUnwrap((root["books"] as? [[String: Any]])?.first)
            let book = try XCTUnwrap(entry["book"] as? [String: Any])
            let deletion = try XCTUnwrap((root["deletions"] as? [[String: Any]])?.first)
            let conversation = try XCTUnwrap((root["conversations"] as? [[String: Any]])?.first)
            let message = try XCTUnwrap((conversation["messages"] as? [[String: Any]])?.first)
            return [
                "root": try XCTUnwrap(root["futureRoot"]),
                "entry": try XCTUnwrap(entry["futureEntry"]),
                "book": try XCTUnwrap(book["futureBook"]),
                "tombstone": try XCTUnwrap(deletion["futureTombstone"]),
                "conversation": try XCTUnwrap(conversation["futureConversation"]),
                "message": try XCTUnwrap(message["futureMessage"])
            ]
        }
        XCTAssertTrue(NSDictionary(dictionary: try unknownValues(originalObject))
            .isEqual(NSDictionary(dictionary: try unknownValues(roundTrippedObject))))
        let rootExtensions = try XCTUnwrap(originalObject["futureRoot"] as? [String: Any])
        XCTAssertTrue(rootExtensions["futureNull"] is NSNull)
        let entryExtensions = try XCTUnwrap((originalObject["books"] as? [[String: Any]])?.first?["futureEntry"] as? [String: Any])
        XCTAssertEqual((entryExtensions["nested"] as? [String: Any])?["keep"] as? Bool, true)
        let bookExtensions = try XCTUnwrap((originalObject["books"] as? [[String: Any]])?.first?["book"] as? [String: Any])
        let nestedArray = try XCTUnwrap((bookExtensions["futureBook"] as? [String: Any])?["x"] as? [Any])
        XCTAssertEqual((nestedArray.first as? NSNumber)?.intValue, 1)
        XCTAssertTrue(nestedArray.last is [String: Any])
        XCTAssertEqual(manifest.conversations.first?.messages.first?.role, .unknown("futureRole"))
    }

    func testKnownFieldEditsAndRecordReplacementRetainOpaqueFields() throws {
        var manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: fixture("nested-unknown.json"))
        let oldBook = try XCTUnwrap(manifest.books.first?.book)
        var replacementBook = Book(id: oldBook.id, title: "Edited title", fileName: oldBook.fileName, format: oldBook.format)
        replacementBook.preserveUnknownFields(from: oldBook)
        manifest.books[0].book = replacementBook

        let oldTombstone = try XCTUnwrap(manifest.deletions.first)
        var replacementTombstone = BookDeletion(bookID: oldTombstone.bookID, deletedAt: oldTombstone.deletedAt)
        replacementTombstone.preserveUnknownFields(from: oldTombstone)
        manifest.deletions[0] = replacementTombstone

        let oldConversation = try XCTUnwrap(manifest.conversations.first)
        var replacementConversation = AIConversationRecord(
            id: oldConversation.id,
            title: "Edited conversation",
            messages: oldConversation.messages,
            createdAt: oldConversation.createdAt,
            modifiedAt: oldConversation.modifiedAt
        )
        replacementConversation.preserveUnknownFields(from: oldConversation)
        manifest.conversations[0] = replacementConversation

        let oldSyncedBook = try XCTUnwrap(manifest.books.first)
        var replacementSyncedBook = SyncedBook(book: oldBook, sha256: oldSyncedBook.sha256)
        replacementSyncedBook.preserveUnknownFields(from: oldSyncedBook)
        replacementSyncedBook.book = replacementBook
        manifest.books[0] = replacementSyncedBook

        let encoded = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["futureRoot"] as? [String: Any])?["futureNull"] as? NSNull, NSNull())
        XCTAssertEqual((((object["books"] as? [[String: Any]])?.first?["futureEntry"] as? [String: Any])?["nested"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual(((object["books"] as? [[String: Any]])?.first?["book"] as? [String: Any])?["title"] as? String, "Edited title")
        XCTAssertNotNil(((object["books"] as? [[String: Any]])?.first?["book"] as? [String: Any])?["futureBook"])
        XCTAssertNotNil(((object["deletions"] as? [[String: Any]])?.first)?["futureTombstone"])
        XCTAssertEqual(((object["conversations"] as? [[String: Any]])?.first?["title"] as? String), "Edited conversation")
        XCTAssertNotNil(((object["conversations"] as? [[String: Any]])?.first?["messages"] as? [[String: Any]])?.first?["futureMessage"])
        XCTAssertNotNil(((object["conversations"] as? [[String: Any]])?.first)?["futureConversation"])
    }

    func testUnsupportedVersionFixtureIsRejectedDuringDecode() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteLibraryManifest.self, from: fixture("unsupported-version.json")))

        var unsupported = RemoteLibraryManifest()
        unsupported.schemaVersion = 2
        XCTAssertThrowsError(try JSONEncoder().encode(unsupported))
    }
}
