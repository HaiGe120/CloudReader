import Foundation
import XCTest
@testable import CloudReader

final class SharedBookInboxTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var inbox: SharedBookInbox!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedBookInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        inbox = SharedBookInbox(containerURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSharedCopySurvivesProviderTemporaryFileAndPreservesName() throws {
        let source = temporaryDirectory.appendingPathComponent("provider-item")
        let contents = Data("A shared book.".utf8)
        try contents.write(to: source)

        let queued = try inbox.stageFile(at: source, suggestedName: "A Shared Book.TXT")
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(queued.lastPathComponent, "A Shared Book.TXT")
        XCTAssertEqual(try inbox.pendingFiles(), [queued])
        XCTAssertEqual(try Data(contentsOf: queued), contents)
        try inbox.removeFile(at: queued)
        XCTAssertTrue(try inbox.pendingFiles().isEmpty)
    }

    func testDuplicateFileNamesKeepBothSharedBooks() throws {
        let source = temporaryDirectory.appendingPathComponent("same.epub")
        try Data("first".utf8).write(to: source)
        let first = try inbox.stageFile(at: source)
        try Data("second".utf8).write(to: source)
        let second = try inbox.stageFile(at: source)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try inbox.pendingFiles().count, 2)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testOnlyCompletedStagingDirectoriesAreVisible() throws {
        let unfinished = temporaryDirectory.appendingPathComponent("SharedBookInbox/.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: unfinished.appendingPathComponent("book.epub"))

        XCTAssertTrue(try inbox.pendingFiles().isEmpty)
    }

    func testProviderTypeRestoresMissingFilenameExtension() throws {
        let source = temporaryDirectory.appendingPathComponent("provider-item")
        try Data("book".utf8).write(to: source)

        let queued = try inbox.stageFile(at: source, suggestedName: "A Book", preferredExtension: "epub")

        XCTAssertEqual(queued.lastPathComponent, "A Book.epub")
    }

    func testSuggestedTitleIsPreservedWhenProviderUsesTemporaryFileName() throws {
        let source = temporaryDirectory.appendingPathComponent("temporary-provider-item.epub")
        try Data("book".utf8).write(to: source)

        let queued = try inbox.stageFile(at: source, suggestedName: "The Original Title")

        XCTAssertEqual(queued.lastPathComponent, "The Original Title.epub")
    }

    func testUnsupportedFilesAndSymlinksAreRejected() throws {
        let source = temporaryDirectory.appendingPathComponent("file.html")
        try Data("unsupported".utf8).write(to: source)
        XCTAssertThrowsError(try inbox.stageFile(at: source))

        let symbolicLink = temporaryDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        XCTAssertThrowsError(try inbox.stageFile(at: symbolicLink))
        XCTAssertTrue(try inbox.pendingFiles().isEmpty)
    }

    func testRemovingQueueEntryCannotDeleteAnExternalFile() throws {
        let source = temporaryDirectory.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)

        XCTAssertThrowsError(try inbox.removeFile(at: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
