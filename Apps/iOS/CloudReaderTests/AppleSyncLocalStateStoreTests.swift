import CloudReaderCore
import Foundation
import XCTest
@testable import CloudReader

final class AppleSyncLocalStateStoreTests: XCTestCase {
    private func isolatedDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleSyncLocalStateStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRecoveryCandidatesAppendDeduplicateAndReopenInStableOrder() async throws {
        let directory = try isolatedDirectory()
        let first = SyncRecoveryCandidate(kind: "book", entityID: "b", field: "title", value: .string("Zulu"))
        let second = SyncRecoveryCandidate(kind: "book", entityID: "a", field: "title", value: .string("Alpha"))
        let store = AppleSyncLocalStateStore(directory: directory)

        try await store.appendRecoveryCandidates([first, second, first])
        try await store.appendRecoveryCandidates([second])

        let loaded = try await AppleSyncLocalStateStore(directory: directory).loadRecoveryCandidates()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded, loaded.sorted { Self.canonical($0).lexicographicallyPrecedes(Self.canonical($1)) })
        XCTAssertEqual(Set(loaded), Set([first, second]))
    }

    func testCorruptRecoveryJournalFailsClosedAndRemainsUnchanged() async throws {
        let directory = try isolatedDirectory()
        let url = directory.appendingPathComponent("sync-recovery-v1.json")
        let corrupt = Data("{not valid json".utf8)
        try corrupt.write(to: url)
        let store = AppleSyncLocalStateStore(directory: directory)
        let candidate = SyncRecoveryCandidate(kind: "book", entityID: "b", value: .string("retained"))

        do {
            try await store.appendRecoveryCandidates([candidate])
            XCTFail("Appending should fail when the existing journal cannot be read")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testRootOpaqueSnapshotReopensAndSaveReplacesPriorFields() async throws {
        let directory = try isolatedDirectory()
        let store = AppleSyncLocalStateStore(directory: directory)
        let initial: [String: JSONValue] = [
            "vendor": .object(["enabled": .bool(true), "labels": .array([.string("one"), .number(Decimal(2))])]),
            "legacy": .null
        ]
        try await store.saveRootOpaqueManifestFields(initial)
        let reopened = try await AppleSyncLocalStateStore(directory: directory).loadRootOpaqueManifestFields()
        XCTAssertEqual(reopened, initial)

        let replacement: [String: JSONValue] = ["vendor": .string("replacement")]
        try await store.saveRootOpaqueManifestFields(replacement)
        let replaced = try await AppleSyncLocalStateStore(directory: directory).loadRootOpaqueManifestFields()
        XCTAssertEqual(replaced, replacement)
    }

    private static func canonical(_ candidate: SyncRecoveryCandidate) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(candidate)) ?? Data()
    }
}
