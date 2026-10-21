import Foundation
import CloudReaderCore
import XCTest
@testable import CloudReader

@MainActor
final class CloudReaderMacContractTests: XCTestCase {
    func testLegacyBookDefaultsAndFoundationReferenceDatePrecision() throws {
        let data = Data(#"{"id":"0E7B7B49-9652-4E82-BA2E-84F58CC90D46","title":"Legacy","fileName":"legacy.txt","format":"txt","addedAt":812345678.125}"#.utf8)

        let book = try JSONDecoder().decode(Book.self, from: data)

        XCTAssertEqual(book.progress, 0)
        XCTAssertFalse(book.isBookmarked)
        XCTAssertNil(book.lastOpenedAt)
        XCTAssertEqual(book.addedAt.timeIntervalSinceReferenceDate, 812345678.125, accuracy: 0.000_001)
        XCTAssertEqual(book.modifiedAt.timeIntervalSinceReferenceDate, book.addedAt.timeIntervalSinceReferenceDate, accuracy: 0.000_001)
    }

    func testMacImportCoordinatorPreservesMixedOutcomesAndRetryAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudReaderMacImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("Good.txt")
        let missing = root.appendingPathComponent("Missing.epub")
        try Data("A Mac imported book".utf8).write(to: good)
        let suiteName = "CloudReaderMacContract-\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library"), defaults: suite)
        let coordinator = BookImportCoordinator()

        coordinator.importFiles([good, missing], library: library)
        try await waitForImport(coordinator)
        XCTAssertEqual(coordinator.lastResult.importedBooks.map(\.title), ["Good"])
        XCTAssertEqual(coordinator.lastResult.rejectedFileNames, ["Missing.epub"])

        let retry = root.appendingPathComponent("Retry.txt")
        try Data("Available for retry".utf8).write(to: retry)
        coordinator.importFiles([retry], library: library)
        coordinator.cancelPendingImports()
        try await waitForImport(coordinator)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.path))

        coordinator.importFiles([retry], library: library)
        try await waitForImport(coordinator)
        XCTAssertEqual(library.books.map(\.title), ["Retry", "Good"])
    }

    private func waitForImport(_ coordinator: BookImportCoordinator) async throws {
        for _ in 0..<300 {
            if !coordinator.isImporting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import did not complete")
    }
}
