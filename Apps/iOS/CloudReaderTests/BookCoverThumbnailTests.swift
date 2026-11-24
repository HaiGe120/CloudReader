import CloudReaderCore
import UIKit
import XCTest
@testable import CloudReader

@MainActor
final class BookCoverThumbnailTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookCoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "BookCoverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func pdf(pages: [UIColor]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 1800)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            for color in pages {
                renderer.beginPage()
                renderer.cgContext.setFillColor(color.cgColor)
                renderer.cgContext.fill(bounds)
            }
        }
    }

    // Convert one center pixel to known RGBA byte order regardless of the thumbnail's color space.
    private func centerPixel(in image: CGImage) throws -> [UInt8] {
        let region = CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)
        let sample = try XCTUnwrap(image.cropping(to: region))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let flags = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                                  bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    func testReloadedLibraryDrawsFirstPDFPageFromManagedCopy() async throws {
        let root = try temporaryDirectory()
        let defaults = try isolatedDefaults()
        let source = root.appendingPathComponent("Two pages.pdf")
        let storage = root.appendingPathComponent("Library")
        try pdf(pages: [.red, .blue]).write(to: source)
        let library = BookLibrary(storageDirectory: storage, defaults: defaults)
        let imported = await library.importBooksAsync(from: [source])
        let original = try XCTUnwrap(imported.importedBooks.first)
        try FileManager.default.removeItem(at: source)

        let reopened = BookLibrary(storageDirectory: storage, defaults: defaults)
        let book = try XCTUnwrap(reopened.books.first { $0.id == original.id })
        let managedURL = try XCTUnwrap(reopened.fileURL(for: book))
        let thumbnail = await BookCoverThumbnails().thumbnail(at: managedURL, format: book.format)

        let image = try XCTUnwrap(thumbnail?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 640)
        let pixel = try centerPixel(in: image)
        XCTAssertGreaterThan(pixel[0], 220)
        XCTAssertLessThan(pixel[2], 35)
    }

    func testSyncedReplacementRefreshesCachedArtworkAtSamePath() async throws {
        let library = BookLibrary(storageDirectory: try temporaryDirectory(), defaults: try isolatedDefaults())
        let book = Book(title: "Synced", fileName: "source.pdf", format: .pdf)
        XCTAssertTrue(library.applySyncedBook(book, contents: pdf(pages: [.red])))
        let existing = try XCTUnwrap(library.books.first)
        let url = try XCTUnwrap(library.fileURL(for: existing))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        let thumbnails = BookCoverThumbnails()
        let before = await thumbnails.thumbnail(at: url, format: existing.format)
        XCTAssertGreaterThan(try centerPixel(in: XCTUnwrap(before?.cgImage))[0], 220)

        XCTAssertTrue(library.applySyncedBook(book, contents: pdf(pages: [.blue])))
        XCTAssertEqual(library.fileURL(for: existing), url)
        let after = await thumbnails.thumbnail(at: url, format: existing.format)
        let pixel = try centerPixel(in: XCTUnwrap(after?.cgImage))
        XCTAssertGreaterThan(pixel[2], 220)
        XCTAssertLessThan(pixel[0], 35)
    }

    func testTextAndDamagedFilesUseTitleCoverFallback() async throws {
        let root = try temporaryDirectory()
        let thumbnails = BookCoverThumbnails()
        for format in BookFormat.allCases {
            let file = root.appendingPathComponent("Text.\(format.rawValue)")
            try Data("A plain text document without artwork.".utf8).write(to: file)
            let image = await thumbnails.thumbnail(at: file, format: format)
            XCTAssertNil(image, format.displayName)
        }
    }

    func testVectorCoverDrawsToBoundedBitmapWithScriptsDisabled() async throws {
        let svg = """
            <?xml version="1.0" encoding="UTF-16"?>
            <s:svg xmlns:s="http://www.w3.org/2000/svg" width="1200" height="1800"
                 onload="document.getElementById('cover').setAttribute('fill', 'blue')">
              <s:rect id="cover" width="1200" height="1800" fill="red"/>
            </s:svg>
            """
        let data = try XCTUnwrap(svg.data(using: .utf16))
        let thumbnail = await SVGCoverThumbnail.thumbnail(data: data, maxPixelSize: 96)
        let image = try XCTUnwrap(thumbnail?.cgImage)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 96)
        let pixel = try centerPixel(in: image)
        XCTAssertGreaterThan(pixel[0], 220)
        XCTAssertLessThan(pixel[2], 35)
    }
}
