import Foundation
import XCTest
import ZIPFoundation
@testable import CloudReader

final class CBZPublicationTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CBZTests-\(UUID().uuidString)", isDirectory: true)
        cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testNaturalOrderingUsesNumericPageNumbers() {
        let values = ["page10.jpg", "page2.jpg", "page1.jpg", "Page02.jpg"]
            .sorted(by: CBZLoader.naturalLess)
        XCTAssertEqual(values, ["page1.jpg", "page2.jpg", "Page02.jpg", "page10.jpg"])
    }

    func testOddFacingSpreadKeepsFinalPageAlone() {
        XCTAssertEqual(CBZLoader.spreadIndices(pageCount: 5, group: 0), [0, 1])
        XCTAssertEqual(CBZLoader.spreadIndices(pageCount: 5, group: 1), [2, 3])
        XCTAssertEqual(CBZLoader.spreadIndices(pageCount: 5, group: 2), [4])
        XCTAssertEqual(CBZLoader.spreadIndices(pageCount: 5, group: 3), [])
    }

    func testPageIndicesStayAlignedToActualSpreadTags() {
        XCTAssertEqual(CBZLoader.alignedPageIndex(3, pageCount: 5, columns: 2), 2)
        XCTAssertEqual(CBZLoader.alignedPageIndex(4, pageCount: 5, columns: 2), 4)
        XCTAssertEqual(CBZLoader.lastGroupStart(pageCount: 5, columns: 2), 4)
        XCTAssertEqual(CBZLoader.lastGroupStart(pageCount: 5, columns: 1), 4)
    }

    func testUnsafePathsAreRejected() {
        for path in ["../outside.jpg", "/outside.jpg", "C:/outside.jpg", "pages\\page.jpg", "pages//page.jpg", "pages/./page.jpg", "pages/../page.jpg"] {
            XCTAssertFalse(CBZLoader.isSafePath(path), path)
        }
        XCTAssertTrue(CBZLoader.isSafePath("pages/page 1.jpg"))
    }

    func testValidArchiveIsOrderedCachedAndOriginalBytesRemainUntouched() async throws {
        let source = try makeArchive([("pages/page10.jpg", Self.pixel), ("pages/page2.png", Self.pixel), ("ComicInfo.xml", Data("<ComicInfo/>".utf8))])
        let original = try Data(contentsOf: source)
        let id = UUID()
        let loader = CBZLoader(cacheRoot: cache)
        let publication = try await loader.open(url: source, bookID: id)
        XCTAssertEqual(publication.pages.map(\.path), ["pages/page2.png", "pages/page10.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent("complete.json").path))
        XCTAssertEqual(try Data(contentsOf: source), original)

        let sentinel = publication.rootURL.appendingPathComponent("cache-reused")
        try Data("yes".utf8).write(to: sentinel)
        let reopened = try await loader.open(url: source, bookID: id)
        XCTAssertEqual(reopened.rootURL, publication.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testUnsafeArchiveEntryLeavesNoCompletedCache() async throws {
        let source = try makeArchive([("../outside.jpg", Self.pixel)])
        let loader = CBZLoader(cacheRoot: cache)
        do {
            _ = try await loader.open(url: source, bookID: UUID())
            XCTFail("Traversal entry should be rejected")
        } catch CBZError.unsafePath { }
        catch { XCTFail("Expected unsafe path error, got \(error)") }
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: cache.path)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside.jpg").path))
    }

    func testAbsoluteDirectoryIsRejectedBeforePreparingPages() async throws {
        let url = directory.appendingPathComponent("directory.cbz")
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "/evil/", type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
        do {
            _ = try await CBZLoader(cacheRoot: cache).open(url: url, bookID: UUID())
            XCTFail("Absolute directory names must not be normalized into relative paths")
        } catch CBZError.unsafePath { }
    }

    func testEncryptedZipEntryIsRejectedEvenWhenImageIsNotDecoded() async throws {
        let source = try makeArchive([("ComicInfo.xml", Data("<ComicInfo/>".utf8)), ("page1.png", Self.pixel)])
        var bytes = try Data(contentsOf: source)
        let centralSignature = Data([0x50, 0x4b, 0x01, 0x02])
        let localSignature = Data([0x50, 0x4b, 0x03, 0x04])
        let central = try XCTUnwrap(bytes.range(of: centralSignature)?.lowerBound)
        let local = try XCTUnwrap(bytes.range(of: localSignature)?.lowerBound)
        bytes[central + 8] |= 1
        bytes[local + 6] |= 1
        try bytes.write(to: source)

        do {
            _ = try await CBZLoader(cacheRoot: cache).open(url: source, bookID: UUID())
            XCTFail("Encrypted ZIP entries must be rejected, including non-image metadata.")
        } catch CBZError.encrypted { }
        catch { XCTFail("Expected encrypted archive error, got \(error)") }
    }

    func testNonImageAndCorruptArchivesFailWithoutCompletionMarker() async throws {
        let nonImage = try makeArchive([("notes.txt", Data("not an image".utf8))])
        let loader = CBZLoader(cacheRoot: cache)
        do {
            _ = try await loader.open(url: nonImage, bookID: UUID())
            XCTFail("Non-image content should fail")
        } catch CBZError.noImages { }
        catch { XCTFail("Expected no image pages error, got \(error)") }

        let corrupt = directory.appendingPathComponent("corrupt.cbz")
        try Data("not a zip archive".utf8).write(to: corrupt)
        do {
            _ = try await loader.open(url: corrupt, bookID: UUID())
            XCTFail("Corrupt content should fail")
        } catch CBZError.invalidArchive { }
        catch { XCTFail("Expected invalid archive error, got \(error)") }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testImageByteLimitIsCheckedBeforeExtraction() async throws {
        let source = directory.appendingPathComponent("large.cbz")
        let archive = try Archive(url: source, accessMode: .create)
        // The advertised expansion is sufficient to exercise the guard; the archive writer
        // emits a compact payload, keeping this boundary test small.
        try archive.addEntry(with: "large.jpg", type: .file, uncompressedSize: 64 * Int64(1_024) * Int64(1_024) + 1, compressionMethod: .none) { _, _ in Data() }
        let loader = CBZLoader(cacheRoot: cache)
        do {
            _ = try await loader.open(url: source, bookID: UUID())
            XCTFail("Oversized image should be rejected")
        } catch CBZError.tooLarge { }
        catch { XCTFail("Expected size-limit error, got \(error)") }
    }

    private func makeArchive(_ entries: [(String, Data)]) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).cbz")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, count in
                bytes.subdata(in: Int(position)..<(Int(position) + count))
            }
        }
        return url
    }

    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p8sAAAAASUVORK5CYII=")!
}
