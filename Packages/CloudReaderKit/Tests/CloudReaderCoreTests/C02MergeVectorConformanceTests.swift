import Foundation
import XCTest
@testable import CloudReaderCore

final class C02MergeVectorConformanceTests: XCTestCase {
    private let expectedIDs: Set<String> = [
        "delete-before-edit", "delete-equal-edit", "delete-after-edit", "newer-edit-keeps-older-tombstone",
        "book-equal-time-portable-tie-and-recovery", "conversation-equal-time-portable-tie",
        "message-union-and-order", "same-message-id-different-payload",
        "opaque-unknown-disjoint-and-equal-values", "opaque-unknown-same-key-conflict",
        "provider-permutations-duplicate-and-retry", "wall-clock-skew-limitation"
    ]
    private let ids = [
        "B1": UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        "C1": UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    ]
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func object(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], file: file, line: line)
    }
    private func array(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [Any] {
        try XCTUnwrap(value as? [Any], file: file, line: line)
    }
    private func string(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(value as? String, file: file, line: line)
    }
    private func number(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        try XCTUnwrap((value as? NSNumber)?.doubleValue, file: file, line: line)
    }
    private func bool(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        try XCTUnwrap((value as? NSNumber)?.boolValue, file: file, line: line)
    }
    private func uuid(_ value: Any?) throws -> UUID {
        let raw = try string(value)
        if let mapped = ids[raw] { return mapped }
        return try XCTUnwrap(UUID(uuidString: raw))
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    private func newManifest() -> RemoteLibraryManifest {
        var result = RemoteLibraryManifest(); result.updatedAt = epoch
        return result
    }
    private func jsonValue(_ value: Any) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func expectedField(_ key: String, _ value: Any) throws -> JSONValue {
        if key == "id", let symbolic = value as? String, let mapped = ids[symbolic] {
            return .string(mapped.uuidString.uppercased())
        }
        return try jsonValue(value)
    }
    private func bookCandidate(_ value: [String: Any]) throws -> SyncedBook {
        let rawBook = try object(value["book"])
        let id = try uuid(rawBook["id"])
        let formatName = try string(rawBook["format"])
        let format = try XCTUnwrap(BookFormat(rawValue: formatName))
        var book = Book(id: id, title: try string(rawBook["title"]), fileName: try string(rawBook["fileName"]), format: format)
        book.addedAt = date(try number(rawBook["addedAt"]))
        book.modifiedAt = date(try number(rawBook["modifiedAt"]))
        book.author = rawBook["author"] as? String
        book.briefDescription = rawBook["briefDescription"] as? String
        book.lastOpenedAt = (rawBook["lastOpenedAt"] as? NSNumber).map { date($0.doubleValue) }
        book.progress = (rawBook["progress"] as? NSNumber)?.doubleValue ?? 0
        book.isBookmarked = (rawBook["isBookmarked"] as? NSNumber)?.boolValue ?? false
        return SyncedBook(book: book, sha256: try string(value["sha256"]))
    }
    private func message(_ value: [String: Any]) throws -> AIConversationMessage {
        let roleName = try string(value["role"])
        let role: AIConversationMessage.Role = roleName == "user" ? .user : (roleName == "assistant" ? .assistant : .unknown(roleName))
        return AIConversationMessage(id: try uuid(value["id"]), role: role, text: try string(value["text"]), createdAt: date(try number(value["createdAt"])))
    }
    private func conversation(_ value: [String: Any]) throws -> AIConversationRecord {
        let messages = try array(value["messages"] ?? []).map { try message(object($0)) }
        return AIConversationRecord(
            id: try uuid(value["id"]), title: try string(value["title"]), messages: messages,
            createdAt: date(try number(value["createdAt"])), modifiedAt: date(try number(value["modifiedAt"]))
        )
    }
    private func manifestWith(messages: [AIConversationMessage], chatID: UUID, modifiedAt: Double) -> RemoteLibraryManifest {
        var value = newManifest()
        value.conversations = [AIConversationRecord(id: chatID, messages: messages, createdAt: epoch, modifiedAt: date(modifiedAt))]
        return value
    }
    private func manifestKey(_ manifest: RemoteLibraryManifest) -> String {
        JCSCanonicalJSON.string(SyncMergePolicy.json(manifest))
    }

    func testEveryC02VectorUsesItsSharedInputsAndExpectedValues() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Contracts/v1/merge-vectors.json").standardizedFileURL
        let root = try object(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        let vectors = try array(root["vectors"]).map { try object($0) }
        let idsInContract = Set(try vectors.map { try string($0["id"]) })
        XCTAssertEqual(idsInContract, expectedIDs)
        XCTAssertEqual(vectors.count, expectedIDs.count)
        var exercised = Set<String>()

        for vector in vectors {
            let vectorID = try string(vector["id"])
            let inputs = try object(vector["inputs"])
            let expected = try object(vector["expected"])
            switch vectorID {
            case "delete-before-edit", "delete-equal-edit", "delete-after-edit":
                let record = try object(inputs["record"]), tombstone = try object(inputs["tombstone"])
                XCTAssertEqual(try uuid(record["id"]), try uuid(tombstone["id"]))
                let recordTime = try number(record["modifiedAt"]), deletedAt = try number(tombstone["deletedAt"])
                var left = newManifest(); left.books = [try bookCandidate(["book": ["id": record["id"]!, "title": "record", "fileName": "record.txt", "format": "txt", "addedAt": 0, "modifiedAt": recordTime], "sha256": String(repeating: "a", count: 64)])]
                var right = newManifest(); right.deletions = [BookDeletion(bookID: try uuid(tombstone["id"]), deletedAt: date(deletedAt))]
                let result = left.merging(right).manifest
                XCTAssertEqual(!result.books.isEmpty, try bool(expected["recordPresent"]), vectorID)
                XCTAssertEqual(!result.deletions.isEmpty, try bool(expected["tombstonePresent"]), vectorID)
                XCTAssertEqual(!result.books.isEmpty, recordTime > deletedAt, vectorID)

            case "newer-edit-keeps-older-tombstone":
                let records = try array(inputs["records"]).map { try object($0) }
                let tombstones = try array(inputs["tombstones"]).map { try object($0) }
                let expectedRecordTime = try number(expected["recordModifiedAt"])
                var left = newManifest()
                left.books = try records.map { row in
                    try bookCandidate(["book": ["id": row["id"]!, "title": String(try number(row["modifiedAt"])), "fileName": "book.txt", "format": "txt", "addedAt": 0, "modifiedAt": try number(row["modifiedAt"])], "sha256": String(repeating: "a", count: 64)])
                }
                left.deletions = try tombstones.map { row in BookDeletion(bookID: try uuid(row["id"]), deletedAt: date(try number(row["deletedAt"]))) }
                let result = left.merging(newManifest()).manifest
                XCTAssertEqual(result.books.first?.book.modifiedAt.timeIntervalSinceReferenceDate, expectedRecordTime)
                XCTAssertEqual(!result.books.isEmpty, try bool(expected["recordPresent"]))
                XCTAssertEqual(!result.deletions.isEmpty, try bool(expected["tombstonePresent"]))
                XCTAssertEqual(result.deletions.first?.deletedAt.timeIntervalSinceReferenceDate, try number(expected["tombstoneDeletedAt"]))

            case "book-equal-time-portable-tie-and-recovery":
                let rows = try array(inputs["candidates"]).map { try object($0) }
                let expectedRecovery = try array(expected["recoveryCandidates"]).map { try object($0) }
                let leftPaths = try object(inputs["deviceLocalPaths"])
                XCTAssertEqual(leftPaths.count, 2) // Present in the vector; local paths are intentionally absent from models.
                var left = newManifest(); left.books = [try bookCandidate(rows[0])]
                var right = newManifest(); right.books = [try bookCandidate(rows[1])]
                let result = left.merging(right)
                let expectedWinner = try expectedRecovery.map { row -> (String, JSONValue) in
                    let candidate = try bookCandidate(row)
                    return (candidate.book.title, .object(["book": SyncMergePolicy.portableBook(candidate.book), "sha256": .string(candidate.sha256)]))
                }.min { JCSCanonicalJSON.less($0.1, $1.1) }?.0
                XCTAssertEqual(result.manifest.books.first?.book.title, expectedWinner)
                XCTAssertEqual(result.recoveryCandidates.filter { $0.kind == "book" }.count, expectedRecovery.count)
                let recoveredTitles = result.recoveryCandidates.filter { $0.kind == "book" }.compactMap { candidate -> String? in
                    guard case .object(let full) = candidate.value, case .object(let book)? = full["book"], case .string(let title)? = book["title"] else { return nil }
                    return title
                }.sorted()
                XCTAssertEqual(recoveredTitles, try expectedRecovery.map { try string(object($0["book"])["title"]) }.sorted())
                let recoveredDigests = result.recoveryCandidates.filter { $0.kind == "book" }.compactMap { candidate -> String? in
                    guard case .object(let full) = candidate.value, case .string(let digest)? = full["sha256"] else { return nil }
                    return digest
                }.sorted()
                XCTAssertEqual(recoveredDigests, try expectedRecovery.map { try string($0["sha256"]) }.sorted())
                for expectedCandidate in expectedRecovery {
                    let digest = try string(expectedCandidate["sha256"])
                    let actual = try XCTUnwrap(result.recoveryCandidates.first { candidate in
                        guard candidate.kind == "book", case .object(let full) = candidate.value,
                              case .string(let actualDigest)? = full["sha256"] else { return false }
                        return actualDigest == digest
                    })
                    guard case .object(let full) = actual.value, case .object(let actualBook)? = full["book"] else {
                        XCTFail("Book recovery candidate must contain its complete book value"); continue
                    }
                    for (key, value) in try object(expectedCandidate["book"]) {
                        XCTAssertEqual(actualBook[key], try expectedField(key, value), "book recovery field \(key)")
                    }
                }
                XCTAssertTrue(try string(expected["primaryRule"]).contains("JCS-first {book, sha256}"))
                XCTAssertTrue(try string(expected["primaryRule"]).contains("changing deviceLocalPaths cannot change the result"))
                XCTAssertEqual(try bool(expected["inputPermutationInvariant"]), manifestKey(left.merging(right).manifest) == manifestKey(right.merging(left).manifest))

            case "conversation-equal-time-portable-tie":
                let rows = try array(inputs["candidates"]).map { try object($0) }
                let left = newManifest(); var leftValue = left
                leftValue.conversations = [try conversation(rows[0])]
                var rightValue = newManifest(); rightValue.conversations = [try conversation(rows[1])]
                let winner = leftValue.merging(rightValue).manifest.conversations.first?.title
                let expectedWinner = try rows.map { row -> (String, JSONValue) in
                    let id = try uuid(row["id"]).uuidString.uppercased()
                    let key: JSONValue = .object([
                        "id": .string(id), "title": .string(try string(row["title"])),
                        "createdAt": .number(Decimal(try number(row["createdAt"]))),
                        "modifiedAt": .number(Decimal(try number(row["modifiedAt"])))
                    ])
                    return (try string(row["title"]), key)
                }.min { JCSCanonicalJSON.less($0.1, $1.1) }?.0
                XCTAssertEqual(winner, expectedWinner)
                XCTAssertEqual(try string(expected["metadataBaseRule"]), "JCS-first portable conversation")
                XCTAssertTrue(try bool(expected["inputPermutationInvariant"]))
                XCTAssertEqual(winner, rightValue.merging(leftValue).manifest.conversations.first?.title)

            case "message-union-and-order":
                let leftRows = try array(inputs["left"]).map { try message(object($0)) }
                let rightRows = try array(inputs["right"]).map { try message(object($0)) }
                let left = manifestWith(messages: leftRows, chatID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!, modifiedAt: max(leftRows.map { $0.createdAt.timeIntervalSinceReferenceDate }.max() ?? 0, 0))
                let right = manifestWith(messages: rightRows, chatID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!, modifiedAt: max(rightRows.map { $0.createdAt.timeIntervalSinceReferenceDate }.max() ?? 0, 0))
                let result = left.merging(right)
                let resultMessages = try XCTUnwrap(result.manifest.conversations.first?.messages)
                let expectedOrder = try array(expected["messageIDsInOrder"]).map { try uuid($0) }
                XCTAssertEqual(resultMessages.map(\.id), expectedOrder)
                var unique: [UUID: AIConversationMessage] = [:]
                for row in leftRows + rightRows { unique[row.id] = row }
                let expectedMessages = unique.values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString.uppercased() < $1.id.uuidString.uppercased() : $0.createdAt < $1.createdAt }
                XCTAssertEqual(resultMessages, expectedMessages)
                XCTAssertEqual(resultMessages.count, expectedMessages.count)
                XCTAssertEqual(try string(expected["duplicateIdenticalPayloads"]), "one message")
                XCTAssertTrue(try bool(expected["repeatMergeUnchanged"]))
                XCTAssertEqual(resultMessages.map(\.id), left.merging(result.manifest).manifest.conversations.first?.messages.map(\.id))

            case "same-message-id-different-payload":
                let rows = try array(inputs["candidates"]).map { try message(object($0)) }
                let expected = try object(vector["expected"])
                let expectedRecovery = try array(expected["recoveryCandidates"]).map { try object($0) }
                let cid = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
                let result = manifestWith(messages: [rows[0]], chatID: cid, modifiedAt: rows[0].createdAt.timeIntervalSinceReferenceDate)
                    .merging(manifestWith(messages: [rows[1]], chatID: cid, modifiedAt: rows[1].createdAt.timeIntervalSinceReferenceDate))
                let idsInManifest = try XCTUnwrap(result.manifest.conversations.first?.messages.map { $0.id.uuidString.uppercased() })
                XCTAssertEqual(idsInManifest, try array(expected["messageIDsInManifest"]).map { try string($0).uppercased() })
                XCTAssertEqual(result.recoveryCandidates.filter { $0.kind == "message" }.count, expectedRecovery.count)
                let expectedWinner = try expectedRecovery.map { try string($0["text"]) }.sorted().first
                XCTAssertEqual(result.manifest.conversations.first?.messages.first?.text, expectedWinner)
                XCTAssertEqual(try string(expected["primaryRule"]), "JCS-first complete portable message")
                let actualPayloads = result.recoveryCandidates.filter { $0.kind == "message" }.compactMap { candidate -> String? in
                    guard case .object(let message) = candidate.value, case .string(let text)? = message["text"] else { return nil }
                    return text
                }.sorted()
                XCTAssertEqual(actualPayloads, try expectedRecovery.map { try string($0["text"]) }.sorted())
                for expectedMessage in expectedRecovery {
                    let expectedID = try uuid(expectedMessage["id"]).uuidString.uppercased()
                    let expectedText = try string(expectedMessage["text"])
                    let actual = try XCTUnwrap(result.recoveryCandidates.first { candidate in
                        guard candidate.kind == "message", case .object(let payload) = candidate.value,
                              case .string(let id)? = payload["id"], case .string(let text)? = payload["text"] else { return false }
                        return id == expectedID && text == expectedText
                    })
                    guard case .object(let payload) = actual.value else { XCTFail("Expected full message payload"); continue }
                    for (key, value) in expectedMessage {
                        XCTAssertEqual(payload[key], try expectedField(key, value), "message recovery field \(key)")
                    }
                }

            case "opaque-unknown-disjoint-and-equal-values":
                let leftFields = try object(inputs["left"]), rightFields = try object(inputs["right"])
                let expectedFields = try object(expected["primaryUnknownFields"])
                var left = newManifest(); left.unknownFields = OpaqueJSONFields(values: try leftFields.mapValues(jsonValue))
                var right = newManifest(); right.unknownFields = OpaqueJSONFields(values: try rightFields.mapValues(jsonValue))
                let result = left.merging(right)
                for (key, value) in expectedFields {
                    XCTAssertEqual(result.manifest.rootUnknownFields[key], try jsonValue(value), key)
                }
                XCTAssertEqual(result.manifest.rootUnknownFields.count, expectedFields.count)
                XCTAssertEqual(result.recoveryCandidates.count, try array(expected["recoveryCandidates"]).count)
                XCTAssertTrue(try bool(expected["repeatMergeUnchanged"]))
                XCTAssertEqual(manifestKey(result.manifest), manifestKey(right.merging(left).manifest))

            case "opaque-unknown-same-key-conflict":
                let leftFields = try object(inputs["left"]), rightFields = try object(inputs["right"])
                var left = newManifest(); left.unknownFields = OpaqueJSONFields(values: try leftFields.mapValues(jsonValue))
                var right = newManifest(); right.unknownFields = OpaqueJSONFields(values: try rightFields.mapValues(jsonValue))
                let result = left.merging(right)
                let recovery = try array(expected["recoveryCandidates"]).map { try object($0) }
                let expectedValues = try recovery.map { try jsonValue($0["value"]!) }.sorted { JCSCanonicalJSON.less($0, $1) }
                let expectedFields = try recovery.map { try string($0["field"]) }.sorted()
                let fieldName = try XCTUnwrap(expectedFields.first)
                let actualCandidates = result.recoveryCandidates.filter { $0.field == fieldName }
                let actualValues = actualCandidates.map(\.value).sorted { JCSCanonicalJSON.less($0, $1) }
                XCTAssertEqual(actualValues, expectedValues)
                XCTAssertEqual(actualCandidates.compactMap(\.field).sorted(), expectedFields)
                XCTAssertEqual(result.manifest.rootUnknownFields[fieldName], expectedValues.first)
                XCTAssertEqual(try string(expected["primaryValueRule"]), "JCS-first complete value for \(fieldName)")
                XCTAssertEqual(try bool(expected["recursiveMerge"]), false)

            case "provider-permutations-duplicate-and-retry":
                let providers = try object(inputs["providers"])
                let orders = try array(inputs["providerOrders"]).map { try array($0).map { try string($0) } }
                let names = providers.keys.sorted()
                let permutations = Set([
                    [names[0], names[1], names[2]], [names[0], names[2], names[1]],
                    [names[1], names[0], names[2]], [names[1], names[2], names[0]],
                    [names[2], names[0], names[1]], [names[2], names[1], names[0]]
                ].map { $0.joined() })
                XCTAssertEqual(Set(orders.map { $0.joined() }), permutations)
                let replay = try object(inputs["replay"])
                let expectedIDs = try array(expected["conversationMessageIDs"]).map { try uuid($0) }
                let tombstoneTime = try number(expected["bookTombstoneDeletedAt"])
                var semanticResults: [String] = []
                for order in orders {
                    var snapshots: [String: RemoteLibraryManifest] = [:]
                    for (name, rawProvider) in providers {
                        let provider = try object(rawProvider)
                        var snapshot = newManifest()
                        if let rawMessages = provider["conversationMessages"] {
                            let messages = try array(rawMessages).map { try message(object($0)) }
                            snapshot = manifestWith(messages: messages, chatID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!, modifiedAt: messages.map { $0.createdAt.timeIntervalSinceReferenceDate }.max() ?? 0)
                        }
                        if let rawTombstone = provider["bookTombstone"] {
                            let value = try object(rawTombstone)
                            snapshot.deletions = [BookDeletion(bookID: try uuid(value["id"]), deletedAt: date(try number(value["deletedAt"])))]
                        }
                        snapshots[name] = snapshot
                    }
                    var accumulated = try XCTUnwrap(order.first.flatMap { snapshots[$0] })
                    for name in order.dropFirst() { accumulated = try XCTUnwrap(snapshots[name]).merging(accumulated).manifest }
                    let duplicateName = try string(replay["provider"])
                    let duplicate = try XCTUnwrap(snapshots[duplicateName])
                    let beforeDuplicate = manifestKey(accumulated)
                    let afterDuplicate = accumulated.merging(duplicate).manifest
                    XCTAssertEqual(manifestKey(afterDuplicate), beforeDuplicate)
                    let retryDescription = try string(replay["afterFailure"])
                    let failedName = try XCTUnwrap(retryDescription.components(separatedBy: "retry ").last?.split(separator: " ").first.map(String.init))
                    XCTAssertTrue(retryDescription.contains("fails once"))
                    let retried = afterDuplicate.merging(try XCTUnwrap(snapshots[failedName])).manifest
                    XCTAssertEqual(retried.conversations.first?.messages.map(\.id), expectedIDs)
                    XCTAssertEqual(retried.deletions.first?.deletedAt, date(tombstoneTime))
                    XCTAssertEqual(manifestKey(retried), beforeDuplicate)
                    semanticResults.append(manifestKey(retried))
                }
                XCTAssertEqual(orders.count, 6)
                XCTAssertEqual(Set(semanticResults).count, 1)
                XCTAssertTrue(try bool(expected["allProviderOrdersSameSemanticState"]))
                XCTAssertTrue(try bool(expected["duplicateSnapshotChangesNothing"]))
                XCTAssertTrue(try bool(expected["retryConvergesToSameSemanticState"]))
                XCTAssertTrue(try string(expected["concurrentUnconditionalManifestWriters"]).contains("may lose unseen updates"))

            case "wall-clock-skew-limitation":
                let deviceA = try object(inputs["deviceA"]), deviceB = try object(inputs["deviceB"])
                let modifiedAt = try number(deviceA["modifiedAt"]), deletedAt = try number(deviceB["deletedAt"])
                var left = newManifest(); left.books = [SyncedBook(book: Book(id: ids["B1"]!, title: "skewed edit", fileName: "book.txt", format: .txt), sha256: String(repeating: "a", count: 64))]
                left.books[0].book.modifiedAt = date(modifiedAt)
                var right = newManifest(); right.deletions = [BookDeletion(bookID: ids["B1"]!, deletedAt: date(deletedAt))]
                let survives = !left.merging(right).manifest.books.isEmpty
                XCTAssertEqual(survives, modifiedAt > deletedAt)
                XCTAssertEqual(try bool(expected["actualRealEventOrderInferred"]), false)
                XCTAssertEqual(try bool(expected["causalGuarantee"]), false)
                XCTAssertTrue(try string(expected["v1TimestampComparison"]).contains("\(Int(modifiedAt)) > \(Int(deletedAt))"))
                XCTAssertTrue(try string(expected["resolution"]).contains("causal protocol"))
                XCTAssertNotEqual(try string(deviceA["realEvent"]), try string(deviceB["realEvent"]))

            default:
                XCTFail("Unimplemented shared C02 vector: \(vectorID)")
            }
            exercised.insert(vectorID)
        }
        XCTAssertEqual(exercised, expectedIDs)
    }
}
