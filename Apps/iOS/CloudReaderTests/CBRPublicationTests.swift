import Foundation
import Dispatch
import ImageIO
import XCTest
@testable import CloudReader

final class CBRPublicationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CBRTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testCorruptInputDoesNotCreateCompletedCache() async throws {
        let source = directory.appendingPathComponent("broken.cbr")
        try Data("not a RAR archive".utf8).write(to: source)
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        do {
            _ = try await CBRLoader(cacheRoot: cache).open(url: source, bookID: UUID())
            XCTFail("Corrupt archive should fail")
        } catch { }
        let cachedChildren = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertTrue(cachedChildren.isEmpty)
    }

    func testRAR4AndRAR5ArchivesAreParsedWithoutImages() async throws {
        for name in ["rar4-no-image", "rar5-no-image"] {
            let source = fixture(name)
            let original = try Data(contentsOf: source)
            do {
                _ = try await CBRLoader(cacheRoot: directory.appendingPathComponent("cache-\(name)", isDirectory: true))
                    .open(url: source, bookID: UUID())
                XCTFail("An archive without images should not produce a comic publication")
            } catch let error as CBRArchiveError {
                if case .noImages = error { } else { XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testExtractsValidPagesFromRAR4AndRAR5SolidAndNonSolidArchives() async throws {
        let names = ["rar4-pages", "rar4-solid-pages", "rar5-pages", "rar5-solid-pages"]
        for name in names {
            let source = fixture(name)
            let original = try Data(contentsOf: source)
            let publication = try await CBRLoader(cacheRoot: directory.appendingPathComponent("cache-\(name)", isDirectory: true))
                .open(url: source, bookID: UUID())

            XCTAssertEqual(publication.pages.map(\.path), ["testfile.jpg", "testfile.png"], name)
            for page in publication.pages {
                let imageURL = publication.rootURL.appendingPathComponent(page.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "Missing extracted page \(page.path) from \(name)")
                guard let image = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      CGImageSourceGetCount(image) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    XCTFail("Extracted page is not a readable image: \(name)/\(page.path)")
                    continue
                }
                XCTAssertGreaterThan(width, 0)
                XCTAssertGreaterThan(height, 0)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent("complete.json").path))
            XCTAssertEqual(try Data(contentsOf: source), original, "The imported archive must remain unchanged")
        }
    }

    func testSolidRAR4SkipsUnrelatedEntryBeforeExtractingPage() async throws {
        let source = fixture("rar4-solid-skip-unrelated")
        let publication = try await CBRLoader(cacheRoot: directory.appendingPathComponent("cache-solid-skip", isDirectory: true))
            .open(url: source, bookID: UUID())

        XCTAssertEqual(publication.pages.map(\.path), ["testfile.png"])
        let imageURL = publication.url(for: 0)
        XCTAssertNotNil(CGImageSourceCreateWithURL(imageURL as CFURL, nil), "The page after the skipped member must be extractable")
    }

    func testResourceLimitsRejectImagesEntriesAndDictionaryBeforePublishingCache() async throws {
        let cases: [(String, CBRResourceLimits)] = [
            ("page-size", CBRResourceLimits(maximumEntries: 10, maximumPageBytes: 1, maximumOutputBytes: .max, maximumDictionaryKiB: .max)),
            ("total-size", CBRResourceLimits(maximumEntries: 10, maximumPageBytes: .max, maximumOutputBytes: 1, maximumDictionaryKiB: .max)),
            ("entry-count", CBRResourceLimits(maximumEntries: 1, maximumPageBytes: .max, maximumOutputBytes: .max, maximumDictionaryKiB: .max)),
            ("dictionary", CBRResourceLimits(maximumEntries: 10, maximumPageBytes: .max, maximumOutputBytes: .max, maximumDictionaryKiB: 0)),
        ]

        for (name, limits) in cases {
            let cache = directory.appendingPathComponent("cache-\(name)", isDirectory: true)
            do {
                _ = try await CBRLoader(cacheRoot: cache, limits: limits).open(url: fixture("rar5-pages"), bookID: UUID())
                XCTFail("The injected \(name) limit should reject the archive")
            } catch let error as CBRArchiveError {
                if case .tooLarge = error { } else { XCTFail("Unexpected error for \(name): \(error)") }
            }
            let cachedChildren = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            XCTAssertTrue(cachedChildren.isEmpty, "\(name) failure must not publish a cache")
        }
    }

    func testCancellationDoesNotPublishCache() async throws {
        let source = fixture("rar5-solid-pages")
        let cache = directory.appendingPathComponent("cache-cancelled", isDirectory: true)
        let barrier = CBRCallbackBarrier()
        let loader = CBRLoader(cacheRoot: cache, onImageChunk: { barrier.pauseAtCallback() })
        let task = Task {
            try await loader.open(url: source, bookID: UUID())
        }
        let callbackReached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let reached = barrier.waitUntilCallback(timeout: .now() + 10)
                if reached { task.cancel() }
                barrier.releaseCallback()
                continuation.resume(returning: reached)
            }
        }
        XCTAssertTrue(callbackReached, "The archive must reach an active UnRAR image-data callback before cancellation")
        do {
            _ = try await task.value
            XCTFail("A cancelled or failed preparation must not return a publication")
        } catch is CancellationError {
            XCTAssertTrue(callbackReached)
        } catch {
            XCTFail("Unexpected preparation failure before cancellation: \(error)")
        }
        let cachedChildren = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertTrue(cachedChildren.isEmpty)
    }

    func testRejectsEncryptedFilesEncryptedHeadersAndSplitVolumes() async throws {
        let cases: [(String, (CBRArchiveError) -> Bool)] = [
            ("encrypted-rar4", { error in if case .encrypted = error { return true }; return false }),
            ("encrypted-headers-rar5", { error in if case .unsupportedArchive = error { return true }; return false }),
            ("split-volume-rar5", { error in if case .unsupportedArchive = error { return true }; return false }),
        ]
        for (name, matches) in cases {
            let source = fixture(name)
            do {
                _ = try await CBRLoader(cacheRoot: directory.appendingPathComponent("cache-\(name)", isDirectory: true))
                    .open(url: source, bookID: UUID())
                XCTFail("\(name) should be rejected")
            } catch let error as CBRArchiveError {
                XCTAssertTrue(matches(error), "Unexpected error for \(name): \(error)")
            }
        }
    }

    func testRejectsAbsoluteDirectoryAndRAR5SymbolicLinks() async throws {
        for name in ["rar4-absolute-directory", "rar5-symlink"] {
            do {
                _ = try await CBRLoader(cacheRoot: directory.appendingPathComponent("cache-\(name)", isDirectory: true))
                    .open(url: fixture(name), bookID: UUID())
                XCTFail("\(name) should be rejected as an unsafe entry")
            } catch let error as CBRArchiveError {
                if case .unsafeEntry = error { } else { XCTFail("Unexpected error for \(name): \(error)") }
            }
        }
    }

    func testNaturalPageOrderingUsesCBZOrdering() {
        let ordered = ["page10.jpg", "page2.jpg", "page1.jpg"].sorted(by: CBZLoader.naturalLess)
        XCTAssertEqual(ordered, ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    private func fixture(_ name: String) -> URL {
        let bundle = Bundle(for: CBRPublicationTests.self)
        guard let url = bundle.url(forResource: name, withExtension: "rar", subdirectory: "CBRFixtures")
                ?? bundle.url(forResource: name, withExtension: "rar") else {
            XCTFail("Missing CBR fixture: \(name)")
            return directory.appendingPathComponent("missing-\(name).rar")
        }
        return url
    }
}

private final class CBRCallbackBarrier: @unchecked Sendable {
    private let callbackEntered = DispatchSemaphore(value: 0)
    private let callbackMayContinue = DispatchSemaphore(value: 0)

    func pauseAtCallback() {
        callbackEntered.signal()
        callbackMayContinue.wait()
    }

    func waitUntilCallback(timeout: DispatchTime) -> Bool { callbackEntered.wait(timeout: timeout) == .success }
    func releaseCallback() { callbackMayContinue.signal() }
}
