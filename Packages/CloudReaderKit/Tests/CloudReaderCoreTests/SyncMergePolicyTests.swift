import Foundation
import XCTest
@testable import CloudReaderCore

final class SyncMergePolicyTests: XCTestCase {
    func testJCSNumbersStringsAndKeyOrdering() {
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "0.000001")!)), "0.000001")
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "1e-7")!)), "1e-7")
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "1e21")!)), "1e+21")
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "-0.000001")!)), "-0.000001")
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "1.23e20")!)), "123000000000000000000")
        XCTAssertEqual(JCSCanonicalJSON.string(.number(Decimal(string: "1.23e21")!)), "1.23e+21")
        XCTAssertEqual(JCSCanonicalJSON.string(.string("é/\n")), "\"é/\\n\"")
        XCTAssertEqual(JCSCanonicalJSON.string(.object(["z": .bool(false), "a": .null])), "{\"a\":null,\"z\":false}")
        XCTAssertEqual(JCSCanonicalJSON.string(.object(["\u{E000}": .null, "😀": .null])), "{\"😀\":null,\"\u{E000}\":null}")
    }

    func testConversationMessageUnionOrderingAndConflictRecovery() {
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSinceReferenceDate: 3)
        let one = AIConversationMessage(id: messageID, role: .user, text: "original", createdAt: date)
        let two = AIConversationMessage(id: messageID, role: .user, text: "different", createdAt: date)
        let a = AIConversationRecord(id: conversationID, messages: [one], createdAt: date, modifiedAt: date)
        let b = AIConversationRecord(id: conversationID, messages: [two, one], createdAt: date, modifiedAt: date)
        let merged = a.merging(b)
        XCTAssertEqual(merged.messages.count, 1)
        XCTAssertEqual(merged.messages[0].id.uuidString, messageID.uuidString.uppercased())
        var left = RemoteLibraryManifest(); left.conversations = [a]
        var right = RemoteLibraryManifest(); right.conversations = [b]
        let combined = left.merging(right)
        XCTAssertEqual(combined.recoveryCandidates.filter { $0.kind == "message" }.count, 2)
        XCTAssertEqual(combined.manifest.conversations.first?.messages.first?.text, "different")
    }

    func testTombstoneEqualTimeSuppressesRecordAndRootOpaqueUnion() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let date = Date(timeIntervalSinceReferenceDate: 5)
        var a = RemoteLibraryManifest(); a.books = [SyncedBook(book: Book(id: id, title: "x", fileName: "x.txt", format: .txt), sha256: String(repeating: "a", count: 64))]
        a.books[0].book.modifiedAt = date
        a.deletions = [BookDeletion(bookID: id, deletedAt: date)]
        let result = a.merging(RemoteLibraryManifest())
        XCTAssertTrue(result.manifest.books.isEmpty)
    }

    func testOpaqueBookFieldsDoNotChangePortableTieWinner() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let date = Date(timeIntervalSinceReferenceDate: 7)
        var alpha = Book(id: id, title: "Alpha", fileName: "book.txt", format: .txt)
        var beta = Book(id: id, title: "Beta", fileName: "book.txt", format: .txt)
        alpha.modifiedAt = date; beta.modifiedAt = date
        alpha.unknownFields = OpaqueJSONFields(values: ["future": .string("z")])
        beta.unknownFields = OpaqueJSONFields(values: ["future": .string("a")])
        var left = RemoteLibraryManifest(); left.books = [SyncedBook(book: beta, sha256: "b")]
        var right = RemoteLibraryManifest(); right.books = [SyncedBook(book: alpha, sha256: "a")]
        let merged = left.merging(right)
        XCTAssertEqual(merged.manifest.books.first?.book.title, "Alpha")
        XCTAssertEqual(merged.manifest.books.first?.book.unknownFields.values["future"], .string("a"))
        XCTAssertTrue(merged.recoveryCandidates.contains { $0.kind == "opaque" && $0.field == "future" && $0.value == .string("z") })
    }

    func testOpaqueConversationAndMessageFieldsDoNotChangePortableTieWinners() {
        let cid = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let mid = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let date = Date(timeIntervalSinceReferenceDate: 8)
        let firstMessage = AIConversationMessage(id: mid, role: .user, text: "Alpha", createdAt: date)
        let secondMessage = AIConversationMessage(id: mid, role: .user, text: "Beta", createdAt: date)
        var messageA = firstMessage; messageA.unknownFields = OpaqueJSONFields(values: ["futureMessage": .string("z")])
        var messageB = secondMessage; messageB.unknownFields = OpaqueJSONFields(values: ["futureMessage": .string("a")])
        var alpha = AIConversationRecord(id: cid, title: "Alpha", messages: [messageB], createdAt: date, modifiedAt: date)
        var beta = AIConversationRecord(id: cid, title: "Beta", messages: [messageA], createdAt: date, modifiedAt: date)
        alpha.unknownFields = OpaqueJSONFields(values: ["futureChat": .string("z")])
        beta.unknownFields = OpaqueJSONFields(values: ["futureChat": .string("a")])
        var left = RemoteLibraryManifest(); left.conversations = [beta]
        var right = RemoteLibraryManifest(); right.conversations = [alpha]
        let merged = left.merging(right)
        let primary = try! XCTUnwrap(merged.manifest.conversations.first)
        XCTAssertEqual(primary.title, "Alpha")
        XCTAssertEqual(primary.messages.first?.text, "Alpha")
        XCTAssertEqual(primary.unknownFields.values["futureChat"], .string("a"))
        XCTAssertEqual(primary.messages.first?.unknownFields.values["futureMessage"], .string("a"))
        XCTAssertTrue(merged.recoveryCandidates.contains { $0.field == "futureChat" && $0.value == .string("z") })
        XCTAssertTrue(merged.recoveryCandidates.contains { $0.field == "futureMessage" && $0.value == .string("z") })
    }
}
