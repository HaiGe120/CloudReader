import Foundation
import XCTest
@testable import CloudReaderCore

final class WireModelTests: XCTestCase {
    func testConversationAndMessageKeysAndFractionalDatesRoundTrip() throws {
        let bookID = UUID(uuidString: "9B3F04FC-65AD-46F4-933F-94C58BC3B7A9")!
        let messageID = UUID(uuidString: "4DE2879D-E2DE-451A-9CD1-5464CE1B393A")!
        let messageDate = Date(timeIntervalSinceReferenceDate: 120.375)
        let createdAt = Date(timeIntervalSinceReferenceDate: 110.125)
        let modifiedAt = Date(timeIntervalSinceReferenceDate: 130.875)
        let message = AIConversationMessage(id: messageID, role: .user, text: "Question", createdAt: messageDate)
        let conversation = AIConversationRecord(
            id: UUID(uuidString: "37B12628-68CB-4C79-870E-2291B1F4E96F")!,
            title: "Question",
            messages: [message],
            bookID: bookID,
            bookTitle: "Book",
            bookDescription: "Description",
            selectedText: "Selection",
            bookContext: "Saved context",
            contextDescription: "Context description",
            includeBookContext: true,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )

        let encoded = try JSONEncoder().encode(conversation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedMessage = try XCTUnwrap((object["messages"] as? [[String: Any]])?.first)

        XCTAssertEqual(Set(object.keys), [
            "id", "title", "messages", "bookID", "bookTitle", "bookDescription", "selectedText",
            "bookContext", "contextDescription", "includeBookContext", "createdAt", "modifiedAt"
        ])
        XCTAssertEqual(Set(encodedMessage.keys), ["id", "role", "text", "createdAt"])
        XCTAssertEqual(object["createdAt"] as? Double ?? .nan, createdAt.timeIntervalSinceReferenceDate, accuracy: 0.000_001)
        XCTAssertEqual(object["modifiedAt"] as? Double ?? .nan, modifiedAt.timeIntervalSinceReferenceDate, accuracy: 0.000_001)
        XCTAssertEqual(encodedMessage["createdAt"] as? Double ?? .nan, messageDate.timeIntervalSinceReferenceDate, accuracy: 0.000_001)
        XCTAssertEqual(try JSONDecoder().decode(AIConversationRecord.self, from: encoded), conversation)
    }

    func testNilConversationFieldsStayOmittedAndDeletionKeysStayStable() throws {
        let date = Date(timeIntervalSinceReferenceDate: 42.625)
        let conversation = AIConversationRecord(
            id: UUID(uuidString: "37B12628-68CB-4C79-870E-2291B1F4E96F")!,
            createdAt: date,
            modifiedAt: date
        )
        let conversationJSON = try JSONEncoder().encode(conversation)
        let conversationObject = try XCTUnwrap(JSONSerialization.jsonObject(with: conversationJSON) as? [String: Any])
        XCTAssertEqual(Set(conversationObject.keys), ["id", "title", "messages", "includeBookContext", "createdAt", "modifiedAt"])

        let deletion = AIConversationDeletion(
            conversationID: conversation.id,
            deletedAt: date
        )
        let deletionJSON = try JSONEncoder().encode(deletion)
        let deletionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: deletionJSON) as? [String: Any])
        XCTAssertEqual(Set(deletionObject.keys), ["conversationID", "deletedAt"])
        XCTAssertEqual(deletionObject["deletedAt"] as? Double ?? .nan, date.timeIntervalSinceReferenceDate, accuracy: 0.000_001)
    }

    func testManifestDefaultsAndWireKeysRemainStable() throws {
        let decoded = try JSONDecoder().decode(RemoteLibraryManifest.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.books.isEmpty)
        XCTAssertTrue(decoded.deletions.isEmpty)
        XCTAssertTrue(decoded.conversations.isEmpty)
        XCTAssertTrue(decoded.conversationDeletions.isEmpty)

        let manifest = RemoteLibraryManifest()
        let encoded = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "updatedAt", "books", "deletions", "conversations", "conversationDeletions"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let restored = try JSONDecoder().decode(RemoteLibraryManifest.self, from: encoded)
        XCTAssertEqual(restored.schemaVersion, manifest.schemaVersion)
        XCTAssertEqual(restored.updatedAt, manifest.updatedAt)
        XCTAssertTrue(restored.books.isEmpty)
        XCTAssertTrue(restored.deletions.isEmpty)
        XCTAssertTrue(restored.conversations.isEmpty)
        XCTAssertTrue(restored.conversationDeletions.isEmpty)
    }

    func testSyncedBookEncodesOnlyBookAndDigest() throws {
        let book = Book(
            id: UUID(uuidString: "A3B54F17-90DD-41E3-A9A3-6D3A163A67D2")!,
            title: "Wire book",
            fileName: "wire.txt",
            format: .txt
        )
        let synced = SyncedBook(book: book, sha256: String(repeating: "a", count: 64))
        let encoded = try JSONEncoder().encode(synced)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["book", "sha256"])
        XCTAssertEqual(try JSONDecoder().decode(SyncedBook.self, from: encoded).sha256, synced.sha256)
    }
}
