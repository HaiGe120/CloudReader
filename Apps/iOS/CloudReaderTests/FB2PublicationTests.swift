import Foundation
import XCTest
@testable import CloudReader

final class FB2PublicationTests: XCTestCase {
    private var directory: URL!
    private var ids: [UUID] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FB2PublicationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FB2", isDirectory: true)
        for id in ids { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true)) }
        try FileManager.default.removeItem(at: directory)
    }

    func testUTF8PreservesMixedInlineOrderAndEscapesText() async throws {
        let xml = Self.document(title: "A & B", body: "<p>Before <emphasis>middle &amp; more</emphasis> after &lt;safe&gt;.</p>")
        let (url, original) = try source(xml)
        let publication = try await open(url)
        let html = try String(contentsOf: publication.url(for: 0), encoding: .utf8)
        XCTAssertEqual(publication.title, "A & B")
        XCTAssertTrue(html.range(of: "Before <em>middle &amp; more</em> after &lt;safe&gt;.") != nil)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testXMLDeclaredLatin1EncodingIsDecoded() async throws {
        let xml = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><FictionBook><description><title-info><book-title>Café</book-title></title-info></description><body><section><p>Crème brûlée</p></section></body></FictionBook>"
        let (url, _) = try source(xml, encoding: .isoLatin1)
        let publication = try await open(url)
        XCTAssertEqual(publication.title, "Café")
        XCTAssertTrue(try String(contentsOf: publication.url(for: 0), encoding: .utf8).contains("Crème brûlée"))
    }

    func testNotesImageAndExternalLinksStayLocalAndSafe() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/WQ0AAAAASUVORK5CYII="))
        let image = png.base64EncodedString()
        let xml = Self.document(body: "<p>Text<a l:href=\"#n1\">note</a><image l:href=\"#cover\"/><a l:href=\"https://example.com/\">outside</a></p><section id=\"n1\"><title><p>Note</p></title><p>Back <a l:href=\"#n1\">here</a></p></section>", extra: "<binary id=\"cover\" content-type=\"image/png\">\(image)</binary>")
        let (url, original) = try source(xml)
        let publication = try await open(url)
        let html = try String(contentsOf: publication.url(for: 0), encoding: .utf8)
        XCTAssertTrue(html.contains("href=\"#n1\""))
        XCTAssertTrue(html.contains("id=\"n1\""))
        XCTAssertTrue(html.contains("class=\"fb2-notes\""))
        XCTAssertTrue(html.contains("Resources/image-1.png"))
        XCTAssertFalse(html.contains("https://example.com"))
        XCTAssertEqual(publication.mediaTypes["Resources/image-1.png"], "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent("Resources/image-1.png").path))
        XCTAssertEqual(publication.rootURL.deletingLastPathComponent().lastPathComponent, ids[0].uuidString)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMalformedXMLFailsWithoutChangingSourceOrPublishingCompletionMarker() async throws {
        let (url, original) = try source("<FictionBook><body><p>broken</body>")
        let id = UUID(); ids.append(id)
        do {
            _ = try await FB2Loader.shared.open(url: url, bookID: id)
            XCTFail("Malformed XML must fail.")
        } catch { XCTAssertTrue(error is EPUBError || error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let cacheRoot = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FB2", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        let markers = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertFalse(markers.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("complete.json").path) })
    }

    func testGeneratedPathsUseOnlyBookIDAndFixedLocalNames() async throws {
        let (url, _) = try source(Self.document(body: "<section id=\"../../outside\"><p>safe</p></section>"))
        let publication = try await open(url)
        XCTAssertEqual(publication.chapters.map(\.path), ["chapter.html"])
        XCTAssertTrue(publication.rootURL.path.contains("/Caches/FB2/\(ids[0].uuidString)/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent("complete.json").path))
    }

    func testPreCancelledOpenStopsBeforePreparingOutput() async throws {
        let (url, original) = try source(Self.document())
        let id = UUID(); ids.append(id)
        let task = Task { try await FB2Loader.shared.open(url: url, bookID: id) }
        task.cancel()
        do { _ = try await task.value }
        catch { XCTAssertTrue(error is CancellationError || error is EPUBError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func open(_ url: URL) async throws -> EPUBPublication {
        let id = UUID(); ids.append(id)
        return try await FB2Loader.shared.open(url: url, bookID: id)
    }

    private func source(_ text: String, encoding: String.Encoding = .utf8) throws -> (URL, Data) {
        let data = try XCTUnwrap(text.data(using: encoding))
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).fb2")
        try data.write(to: url)
        return (url, data)
    }

    private static func document(title: String = "Test book", body: String = "<section><p>Text</p></section>", extra: String = "") -> String {
        let escapedTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><FictionBook xmlns:l=\"http://www.w3.org/1999/xlink\"><description><title-info><book-title>\(escapedTitle)</book-title></title-info></description><body><section>\(body)</section></body><body name=\"notes\"><section>Notes</section></body>\(extra)</FictionBook>"
    }
}
