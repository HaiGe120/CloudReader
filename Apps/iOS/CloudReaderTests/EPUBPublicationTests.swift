import Foundation
import XCTest
import ZIPFoundation
@testable import CloudReader

final class EPUBPublicationTests: XCTestCase {
    private var directory: URL!
    private var bookIDs: [UUID] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBPublicationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("EPUB", isDirectory: true)
        for id in bookIDs { try? FileManager.default.removeItem(at: cache.appendingPathComponent(id.uuidString, isDirectory: true)) }
        try FileManager.default.removeItem(at: directory)
    }

    func testEPUB3UsesSpineOrderAndNavigationLabelsRatherThanZIPOrder() async throws {
        let package = Self.package(
            manifest: """
            <item id="first" href="first.xhtml" media-type="application/xhtml+xml"/>
            <item id="bonus" href="bonus.xhtml" media-type="application/xhtml+xml"/>
            <item id="second" href="second.xhtml" media-type="application/xhtml+xml"/>
            <item id="navigation" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            """,
            spine: "<itemref idref=\"second\"/><itemref idref=\"bonus\" linear=\"no\"/><itemref idref=\"first\"/>"
        )
        let url = try archive([
            ("OPS/first.xhtml", Self.chapter("First archive entry")),
            ("OPS/bonus.xhtml", Self.chapter("Nonlinear bonus")),
            ("META-INF/container.xml", Self.container()),
            ("OPS/package.opf", package),
            ("OPS/second.xhtml", Self.chapter("Second archive entry")),
            ("OPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="toc"><ol><li><a href="first.xhtml#start">First &amp; Opening</a></li><li><a href="second.xhtml">Second chapter</a></li></ol></nav>
            </body></html>
            """)
        ])

        let publication = try await open(url)

        XCTAssertEqual(publication.title, "A Test Book")
        XCTAssertEqual(publication.chapters.map(\.path), ["OPS/second.xhtml", "OPS/first.xhtml"])
        XCTAssertEqual(publication.chapters.map(\.title), ["Second chapter", "First & Opening"])
        XCTAssertTrue(try String(contentsOf: publication.url(for: 0), encoding: .utf8).contains("Second archive entry"))
    }

    func testPercentEncodedChapterAndParentRelativeResourcesStayInsideBook() async throws {
        let url = try archive([
            ("META-INF/container.xml", Self.container()),
            ("OPS/package.opf", Self.package(
                manifest: """
                <item id="chapter" href="../Text/First%20Chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                """,
                spine: "<itemref idref=\"chapter\"/>"
            )),
            ("OPS/nav.xhtml", "<html><body><nav><a href=\"../Text/First%20Chapter.xhtml#start\">An encoded chapter</a></nav></body></html>"),
            ("Text/First Chapter.xhtml", "<html><head><link rel=\"stylesheet\" href=\"../Styles/reader.css\"/></head><body><img src=\"../Images/cover%20image.svg\"/></body></html>"),
            ("Styles/reader.css", "body { color: black; }"),
            ("Images/cover image.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
        ])

        let publication = try await open(url)
        XCTAssertEqual(publication.chapters.first?.path, "Text/First Chapter.xhtml")
        XCTAssertEqual(publication.chapters.first?.title, "An encoded chapter")
        let chapterDirectory = publication.url(for: 0).deletingLastPathComponent()
        let stylesheet = try EPUBLoader.resolve("../Styles/reader.css", relativeTo: chapterDirectory, root: publication.rootURL)
        let image = try EPUBLoader.resolve("../Images/cover%20image.svg", relativeTo: chapterDirectory, root: publication.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stylesheet.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testEPUB2NCXProvidesChapterLabels() async throws {
        let url = try archive([
            ("META-INF/container.xml", Self.container()),
            ("OPS/package.opf", Self.package(
                manifest: "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"toc\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
                spine: "<itemref idref=\"chapter\"/>", version: "2.0"
            )),
            ("OPS/chapter.xhtml", Self.chapter("An EPUB 2 chapter")),
            ("OPS/toc.ncx", """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="chapter" playOrder="1"><navLabel><text>Older book chapter</text></navLabel><content src="chapter.xhtml#section"/></navPoint></navMap></ncx>
            """)
        ])

        let publication = try await open(url)

        XCTAssertEqual(publication.chapters, [EPUBChapter(path: "OPS/chapter.xhtml", title: "Older book chapter")])
    }

    func testOpeningAgainReusesPreparedCacheAndReplacementInvalidatesIt() async throws {
        let url = try archive(Self.simpleEntries(title: "Original book", text: "Original chapter"))
        let id = UUID()
        let publication = try await open(url, id: id)
        let sentinel = publication.rootURL.appendingPathComponent("cache-reuse-marker.txt")
        try Data("retained".utf8).write(to: sentinel)

        let reopened = try await open(url, id: id)
        XCTAssertEqual(reopened.rootURL, publication.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try FileManager.default.removeItem(at: url)
        _ = try archive(Self.simpleEntries(title: "A replacement book with a longer title", text: "Replacement chapter contents"), at: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)
        let replaced = try await open(url, id: id)

        XCTAssertEqual(replaced.title, "A replacement book with a longer title")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(try String(contentsOf: replaced.url(for: 0), encoding: .utf8).contains("Replacement chapter contents"))
    }

    func testMissingPreparedChapterIsRebuiltFromOriginal() async throws {
        let url = try archive(Self.simpleEntries())
        let id = UUID()
        let publication = try await open(url, id: id)
        try FileManager.default.removeItem(at: publication.url(for: 0))

        let rebuilt = try await open(url, id: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: rebuilt.url(for: 0).path))
    }

    func testMissingPackageCannotOpen() async throws {
        let url = try archive([("META-INF/container.xml", Self.container())])
        do {
            _ = try await open(url)
            XCTFail("An EPUB with a missing package must fail.")
        } catch { }
    }

    func testMalformedPackageReportsInvalidBook() async throws {
        let url = try archive([("META-INF/container.xml", Self.container()), ("OPS/package.opf", "<package><manifest>")])
        do {
            _ = try await open(url)
            XCTFail("Malformed package XML must fail.")
        } catch EPUBError.invalidBook { }
        catch { XCTFail("Expected an invalid-book error, got \(error).") }
    }

    func testPackageWithNoReadableSpineReportsNoChapters() async throws {
        let url = try archive([("META-INF/container.xml", Self.container()), ("OPS/package.opf", Self.package(manifest: "", spine: ""))])
        do {
            _ = try await open(url)
            XCTFail("A package without readable chapters must fail.")
        } catch EPUBError.noChapters { }
        catch { XCTFail("Expected a no-chapters error, got \(error).") }
    }

    func testZIPTraversalAbsoluteAndBackslashPathsAreRejectedBeforeExtraction() async throws {
        for path in ["../outside.xhtml", "/outside.xhtml", "OPS/../../outside.xhtml", "OPS\\outside.xhtml"] {
            let url = try archive([(path, "untrusted")])
            do {
                _ = try await open(url)
                XCTFail("Unsafe ZIP entry \(path) must fail.")
            } catch EPUBError.unsafePath { }
            catch { XCTFail("Expected an unsafe-path error for \(path), got \(error).") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("outside.xhtml").path))
    }

    func testZIPSymbolicLinksAreRejected() async throws {
        let url = directory.appendingPathComponent("symlink.epub")
        let archive = try Archive(url: url, accessMode: .create)
        let target = Data("../../outside.xhtml".utf8)
        try archive.addEntry(with: "OPS/link.xhtml", type: .symlink, uncompressedSize: Int64(target.count)) { position, count in
            target.subdata(in: Int(position)..<(Int(position) + count))
        }
        do {
            _ = try await open(url)
            XCTFail("Symbolic-link ZIP entries must fail.")
        } catch EPUBError.unsafePath { }
        catch { XCTFail("Expected an unsafe-path error, got \(error).") }
    }

    func testEncryptedBookReportsDRMAndFontObfuscationStillOpens() async throws {
        let encryption: (String) -> String = { algorithm in
            "<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><EncryptedData xmlns=\"http://www.w3.org/2001/04/xmlenc#\"><EncryptionMethod Algorithm=\"\(algorithm)\"/></EncryptedData></encryption>"
        }
        let protected = try archive(Self.simpleEntries() + [("META-INF/encryption.xml", encryption("http://www.w3.org/2001/04/xmlenc#aes128-cbc"))])
        do {
            _ = try await open(protected)
            XCTFail("DRM-encrypted content must fail explicitly.")
        } catch EPUBError.encrypted { }
        catch { XCTFail("Expected a DRM error, got \(error).") }

        let obfuscatedFont = try archive(Self.simpleEntries() + [("META-INF/encryption.xml", encryption("http://www.idpf.org/2008/embedding"))])
        let publication = try await open(obfuscatedFont)
        XCTAssertEqual(publication.chapters.count, 1)
    }

    func testPackageResourceResolutionRejectsExternalAndEscapingURLs() throws {
        let root = directory.appendingPathComponent("root", isDirectory: true)
        let base = root.appendingPathComponent("OPS", isDirectory: true)
        for href in ["../../outside.xhtml", "%2e%2e/%2e%2e/outside.xhtml", "https://example.com/chapter.xhtml", "//example.com/chapter.xhtml", "/outside.xhtml", "..\\outside.xhtml"] {
            XCTAssertThrowsError(try EPUBLoader.resolve(href, relativeTo: base, root: root), href)
        }
    }

    func testSharedResourcePolicyKeepsParentRelativePathsInsideRoot() throws {
        let root = directory.appendingPathComponent("prepared", isDirectory: true)
        let ops = root.appendingPathComponent("OPS", isDirectory: true)
        let styles = root.appendingPathComponent("Styles", isDirectory: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        let stylesheet = try EPUBResourcePolicy.resourceURL(root: root, relativePath: "OPS/../Styles/book.css")
        XCTAssertEqual(stylesheet.standardizedFileURL, styles.appendingPathComponent("book.css").standardizedFileURL)
        XCTAssertThrowsError(try EPUBResourcePolicy.resourceURL(root: root, relativePath: "../../outside.css")) { error in
            guard case EPUBError.unsafePath = error else { return XCTFail("Expected unsafe path, got \(error).") }
        }
        XCTAssertThrowsError(try EPUBResourcePolicy.resourceURL(root: root, relativePath: "OPS\\outside.css"))
    }

    func testSharedResourcePolicyRejectsSymlinksEscapingRootButAllowsContainedLinks() throws {
        let root = directory.appendingPathComponent("prepared", isDirectory: true)
        let outside = directory.appendingPathComponent("outside.css")
        let inside = root.appendingPathComponent("Styles/inside.css")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("body{}".utf8).write(to: inside)
        try Data("outside{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside.css"), withDestinationURL: inside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside.css"), withDestinationURL: outside)

        XCTAssertEqual(try EPUBResourcePolicy.resourceURL(root: root, relativePath: "inside.css"), inside.resolvingSymlinksInPath())
        XCTAssertThrowsError(try EPUBResourcePolicy.resourceURL(root: root, relativePath: "outside.css")) { error in
            guard case EPUBError.unsafePath = error else { return XCTFail("Expected unsafe path, got \(error).") }
        }
    }

    func testSharedResourcePolicyNormalizesMIMEAndAddsHTMLContentPolicy() throws {
        let resource = directory.appendingPathComponent("chapter.xhtml")
        let source = Data("<HTML><HEAD class=\"book\"></HEAD><body>Chapter</body></HTML>".utf8)
        let prepared = try EPUBResourcePolicy.prepare(
            data: source,
            resourceURL: resource,
            requestPath: "OPS/chapter.xhtml",
            mediaTypes: ["OPS/chapter.xhtml": " Application/XHTML+XML ; charset=utf-8"],
            fallbackMIMEType: "application/octet-stream"
        )
        let html = try XCTUnwrap(String(data: prepared.data, encoding: .utf8))
        XCTAssertEqual(prepared.mimeType, "text/html")
        let headEnd = try XCTUnwrap(html.range(of: "<HEAD class=\"book\">")?.upperBound)
        let policyStart = try XCTUnwrap(html.range(of: "<meta http-equiv=\"Content-Security-Policy\"")?.lowerBound)
        XCTAssertEqual(headEnd, policyStart)
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertEqual(EPUBResourcePolicy.normalizedMIMEType(" Image/SVG+XML ; charset=utf-8 "), "image/svg+xml")
        XCTAssertEqual(EPUBResourcePolicy.normalizedMIMEType("  "), "application/octet-stream")
    }

    func testProgressRoundTripsAndHandlesBoundariesAndNonfiniteValues() {
        for count in [1, 2, 7, 30] {
            for progress in [0.0, 0.01, 0.25, 0.5, 0.99, 1.0] {
                let location = EPUBPublication.location(progress: progress, chapterCount: count)
                XCTAssertTrue((0..<count).contains(location.chapter))
                XCTAssertEqual(EPUBPublication.progress(chapter: location.chapter, fraction: location.fraction, chapterCount: count), progress, accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(EPUBPublication.location(progress: 1, chapterCount: 3).chapter, 2)
        XCTAssertEqual(EPUBPublication.location(progress: .nan, chapterCount: 3).fraction, 0)
        XCTAssertEqual(EPUBPublication.location(progress: .infinity, chapterCount: 3).chapter, 0)
        XCTAssertEqual(EPUBPublication.progress(chapter: 0, fraction: .nan, chapterCount: 3), 0)
        XCTAssertEqual(EPUBPublication.progress(chapter: 0, fraction: 1, chapterCount: 0), 0)
    }

    private func open(_ url: URL, id: UUID = UUID()) async throws -> EPUBPublication {
        if !bookIDs.contains(id) { bookIDs.append(id) }
        return try await EPUBLoader.shared.open(url: url, bookID: id)
    }

    private func archive(_ entries: [(String, String)], at existingURL: URL? = nil) throws -> URL {
        let url = existingURL ?? directory.appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)
        let entries = entries.contains(where: { $0.0 == "mimetype" }) ? entries : [("mimetype", "application/epub+zip")] + entries
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: path == "mimetype" ? .none : .deflate) { position, count in
                data.subdata(in: Int(position)..<(Int(position) + count))
            }
        }
        return url
    }

    private static func simpleEntries(title: String = "A Test Book", text: String = "A test chapter") -> [(String, String)] {
        [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", container()),
            ("OPS/package.opf", package(manifest: "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>", spine: "<itemref idref=\"chapter\"/>", title: title)),
            ("OPS/chapter.xhtml", chapter(text))
        ]
    }

    private static func container() -> String {
        "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
    }

    private static func package(manifest: String, spine: String, title: String = "A Test Book", version: String = "3.0") -> String {
        "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"\(version)\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(title)</dc:title></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
    }

    private static func chapter(_ text: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Test</title></head><body><p>\(text)</p></body></html>"
    }
}
