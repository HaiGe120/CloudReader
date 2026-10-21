import XCTest
@testable import CloudReader

final class KindlePublicationTests: XCTestCase {
    func testRecognizesMOBI6AndSupportedCompressionVariants() throws {
        for compression: UInt16 in [1, 2, 17480] {
            let info = try KindlePreflight.inspect(fixture(version: 6, compression: compression))
            XCTAssertEqual(info.generation, .mobi6)
            XCTAssertEqual(info.compression, compression)
            XCTAssertEqual(info.textRecordCount, 1)
        }
    }

    func testRecognizesKF8() throws {
        XCTAssertEqual(try KindlePreflight.inspect(fixture(version: 8)).generation, .kf8)
    }

    func testRecognizesComboMOBIFromEXTHBoundary() throws {
        XCTAssertEqual(try KindlePreflight.inspect(fixture(combo: true)).generation, .combo)
    }

    func testRejectsEncryptedPalmDOCRecordBeforeDecoder() throws {
        XCTAssertThrowsError(try KindlePreflight.inspect(fixture(encryption: 1))) { error in
            XCTAssertEqual(error as? KindleDecodeError, .drmProtected)
        }
    }

    func testRejectsUnknownCompressionAndTruncatedRecordTables() throws {
        XCTAssertThrowsError(try KindlePreflight.inspect(fixture(compression: 99))) { error in
            XCTAssertEqual(error as? KindleDecodeError, .unsupportedCompression)
        }
        XCTAssertThrowsError(try KindlePreflight.inspect(Data(repeating: 0, count: 100)))
    }

    func testPreflightDoesNotModifySourceBytes() throws {
        let original = fixture(version: 8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kindle-\(UUID().uuidString).mobi")
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)
        _ = try KindlePreflight.inspect(Data(contentsOf: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTruncatedHeadersAndEveryTruncatedPrefixAreRejectedSafely() throws {
        let complete = mobi6Fixture()
        for length in 0..<complete.count {
            // Some complete record payloads can be shorter; preflight checks the
            // container and headers, leaving image decoding to preparation.
            if length < 400 { XCTAssertThrowsError(try KindlePreflight.inspect(complete.prefix(length))) }
        }
        var malformed = fixture()
        malformed.replaceSubrange(86..<90, with: [0, 0, 0, 110])
        XCTAssertThrowsError(try KindlePreflight.inspect(malformed))
    }

    func testEncryptedComboSecondaryHeaderIsRejectedBeforeDecoding() throws {
        var bytes = fixture(combo: true)
        bytes[450 + 12] = 0; bytes[450 + 13] = 1
        XCTAssertThrowsError(try KindlePreflight.inspect(bytes)) { error in
            XCTAssertEqual(error as? KindleDecodeError, .drmProtected)
        }
    }

    func testDictionaryAndFixedLayoutHeadersAreRejected() throws {
        var dictionary = fixture()
        dictionary.replaceSubrange((94 + 40)..<(94 + 44), with: [0, 0, 0, 1])
        XCTAssertThrowsError(try KindlePreflight.inspect(dictionary)) { error in
            XCTAssertEqual(error as? KindleDecodeError, .unsupportedFormat)
        }
        var fixed = fixture()
        fixed[94 + 128] = 0; fixed[94 + 131] = 0x40
        let exth = 94 + 248
        let metadata: [UInt8] = Array("EXTH".utf8) + [0, 0, 0, 23, 0, 0, 0, 1, 0, 0, 0, 122, 0, 0, 0, 11] + Array("yes".utf8)
        fixed.replaceSubrange(exth..<(exth + metadata.count), with: metadata)
        XCTAssertThrowsError(try KindlePreflight.inspect(fixed)) { error in
            XCTAssertEqual(error as? KindleDecodeError, .unsupportedFormat)
        }
    }

    func testPrintReplicaPayloadIsRejectedWithoutPublishingCache() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("print-replica-\(UUID()).mobi")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KindleReplica-\(UUID())")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        try mobi6Fixture(content: "%MOPunsupported print replica").write(to: source)
        do {
            _ = try await KindleLoader(cacheRoot: root).open(url: source, bookID: UUID())
            XCTFail("Print replica cannot be rendered as reflowable text")
        } catch { XCTAssertEqual(error as? KindleDecodeError, .unsupportedFormat) }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertFalse(files.contains { $0.lastPathComponent == "complete.json" })
    }

    func testConcurrentOpensShareCompletedCacheAndKeepResources() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rich-kf8-image-links", withExtension: "azw3"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KindleConcurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = KindleLoader(cacheRoot: root), bookID = UUID()
        async let first = loader.open(url: source, bookID: bookID)
        async let second = loader.open(url: source, bookID: bookID)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.rootURL, b.rootURL)
        for path in a.mediaTypes.keys { XCTAssertTrue(FileManager.default.fileExists(atPath: b.rootURL.appendingPathComponent(path).path)) }
    }

    func testLocalWebKitExporterWritesChapterAndImageAndPreservesOriginal() async throws {
        let original = mobi6Fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kindle-\(UUID().uuidString).mobi")
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KindleTests-\(UUID().uuidString)", isDirectory: true)
        let bookID = UUID()
        defer {
            try? FileManager.default.removeItem(at: url)
            if FileManager.default.fileExists(atPath: cacheRoot.path) {
                try? FileManager.default.removeItem(at: cacheRoot)
            }
        }
        try original.write(to: url)
        let publication = try await KindleLoader(cacheRoot: cacheRoot).open(url: url, bookID: bookID)
        XCTAssertEqual(publication.chapters.count, 1)
        XCTAssertEqual(publication.mediaTypes.values.first, "image/png")
        let imagePath = try XCTUnwrap(publication.mediaTypes.first?.key)
        XCTAssertEqual(Array(try Data(contentsOf: publication.rootURL.appendingPathComponent(imagePath)).prefix(8)),
                       [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let html = try String(contentsOf: publication.url(for: 0), encoding: .utf8)
        XCTAssertTrue(html.contains("Hello Kindle"))
        XCTAssertTrue(html.contains("../Resources/resource-00001.png"))
        XCTAssertTrue(html.contains("#filepos"))
        XCTAssertFalse(html.contains("https://example.com"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent("complete.json").path))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testIndependentKF8AndComboFixturesExportRealChapters() async throws {
        for (name, ext, generation) in [
            ("reflowable-kf8", "azw3", KindleContainerInfo.Generation.kf8),
            ("reflowable-combo", "mobi", .combo),
        ] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
            let original = try Data(contentsOf: source)
            XCTAssertEqual(try KindlePreflight.inspect(original).generation, generation)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("KindleFixture-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let publication = try await KindleLoader(cacheRoot: root).open(url: source, bookID: UUID())
            XCTAssertGreaterThanOrEqual(publication.chapters.count, 2, name)
            let chapters = try publication.chapters.indices.map {
                try String(contentsOf: publication.url(for: $0), encoding: .utf8)
            }
            XCTAssertTrue(chapters.allSatisfy { $0.contains("<body") }, name)
            XCTAssertTrue(chapters.contains { $0.contains("At dusk, Mara lit the beacon and watched its quiet beam cross the bay.") }, name)
            XCTAssertTrue(chapters.contains { $0.contains("The Return") }, name)
            XCTAssertFalse(chapters.joined().contains("kindle:embed:"), "Kindle resources must resolve to local files")
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testHUFFCDICFixtureDecodesTextAndKeepsOriginalBytes() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "huffdic-unicode", withExtension: "mobi"))
        let original = try Data(contentsOf: source)
        XCTAssertEqual(try KindlePreflight.inspect(original).compression, 17480)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KindleHUFF-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let publication = try await KindleLoader(cacheRoot: root).open(url: source, bookID: UUID())
        let text = try publication.chapters.indices.map { try String(contentsOf: publication.url(for: $0), encoding: .utf8) }.joined()
        XCTAssertGreaterThan(text.utf8.count, 10_000)
        XCTAssertFalse(text.contains("\u{fffd}"), "Valid UTF-8 content must survive HUFF decompression")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testKF8ExportsChineseImagesCSSAndCrossChapterLinks() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rich-kf8-image-links", withExtension: "azw3"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KindleRich-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let publication = try await KindleLoader(cacheRoot: root).open(url: source, bookID: UUID())
        let html = try publication.chapters.indices.map { try String(contentsOf: publication.url(for: $0), encoding: .utf8) }.joined()
        XCTAssertTrue(html.contains("海风穿过松林"))
        XCTAssertTrue(publication.mediaTypes.values.contains("image/jpeg"))
        XCTAssertTrue(publication.mediaTypes.values.contains("text/css"))
        XCTAssertTrue(html.contains("chapter-00002.html#"), "The Kindle note link must target a prepared chapter")
        XCTAssertFalse(html.contains("kindle:embed:"))
        XCTAssertFalse(html.contains("kindle:pos:"))
        for path in publication.mediaTypes.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: publication.rootURL.appendingPathComponent(path).path))
        }
    }

    private func fixture(version: UInt32 = 6, compression: UInt16 = 2, encryption: UInt16 = 0, combo: Bool = false) -> Data {
        let offsets = combo ? [110, 430, 450, 770] : [94, 414]
        var data = [UInt8](repeating: 0, count: offsets.last! + 100)
        func put16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 0xff)
        }
        func put32(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8(value >> 24); data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff); data[offset + 3] = UInt8(value & 0xff)
        }
        Array("BOOKMOBI".utf8).enumerated().forEach { data[60 + $0.offset] = $0.element }
        put16(UInt16(offsets.count), at: 76)
        for (index, offset) in offsets.enumerated() { put32(UInt32(offset), at: 78 + index * 8) }
        for (record, generation) in combo ? [(0, UInt32(6)), (2, UInt32(8))] : [(0, version)] {
            let first = offsets[record]
            put16(compression, at: first); put16(1, at: first + 8); put16(4096, at: first + 10); put16(encryption, at: first + 12)
            Array("MOBI".utf8).enumerated().forEach { data[first + 16 + $0.offset] = $0.element }
            put32(generation == 8 ? 248 : 232, at: first + 20)
            put32(2, at: first + 24); put32(65001, at: first + 28); put32(generation, at: first + 36)
        }
        if combo {
            let first = offsets[0]
            put32(0x40, at: first + 128)
            let exth = first + 16 + 232
            Array("EXTH".utf8).enumerated().forEach { data[exth + $0.offset] = $0.element }
            put32(24, at: exth + 4); put32(1, at: exth + 8); put32(121, at: exth + 12)
            put32(12, at: exth + 16); put32(2, at: exth + 20)
        }
        return Data(data)
    }

    private func mobi6Fixture(content: String? = nil) -> Data {
        let prefix = "<html><head><title>Local test</title></head><body><p>Hello Kindle</p>"
        let filePosition = prefix.utf8.count
        let html = prefix + "<a filepos=\"\(filePosition)\">jump</a><img recindex=\"1\"><a href=\"https://example.com\">remote</a></body></html>"
        let text = Array((content ?? html).utf8)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jW0sAAAAASUVORK5CYII=")!
        // Keep title bytes in record zero, after its declared MOBI header, and before
        // the first text record begins.
        let record0 = 102, record1 = 400, record2 = record1 + text.count
        var data = [UInt8](repeating: 0, count: record2 + png.count)
        func put16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 0xff)
        }
        func put32(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8(value >> 24); data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff); data[offset + 3] = UInt8(value & 0xff)
        }
        Array("BOOKMOBI".utf8).enumerated().forEach { data[60 + $0.offset] = $0.element }
        put16(3, at: 76); put32(UInt32(record0), at: 78); put32(UInt32(record1), at: 86); put32(UInt32(record2), at: 94)
        put16(1, at: record0); put16(1, at: record0 + 8); put16(4096, at: record0 + 10)
        Array("MOBI".utf8).enumerated().forEach { data[record0 + 16 + $0.offset] = $0.element }
        put32(232, at: record0 + 20); put32(2, at: record0 + 24); put32(65001, at: record0 + 28); put32(6, at: record0 + 36)
        put32(2, at: record0 + 108); put32(248, at: record0 + 84); put32(10, at: record0 + 88)
        Array("Local test".utf8.prefix(10)).enumerated().forEach { data[record0 + 248 + $0.offset] = $0.element }
        data.replaceSubrange(record1..<(record1 + text.count), with: text)
        data.replaceSubrange(record2..<(record2 + png.count), with: png)
        return Data(data)
    }
}
