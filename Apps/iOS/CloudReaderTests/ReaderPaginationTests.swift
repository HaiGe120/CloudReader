import CloudReaderCore
import UIKit
import XCTest
@testable import CloudReader

@MainActor
final class ReaderPaginationTests: XCTestCase {
    func testSavedProgressRestoresEveryPageInLongBooks() {
        for pageCount in [22, 49, 99, 101, 233, 600] {
            for pagesPerGroup in [1, 2] {
                let groups = ReaderPagination.pageGroupCount(pageCount: pageCount, pagesPerGroup: pagesPerGroup)
                for group in 0..<groups {
                    let progress = ReaderPagination.progress(
                        pageGroupIndex: group,
                        pageCount: pageCount,
                        pagesPerGroup: pagesPerGroup
                    )
                    XCTAssertEqual(
                        ReaderPagination.pageGroupIndex(progress: progress, pageCount: pageCount, pagesPerGroup: pagesPerGroup),
                        group,
                        "Page count \(pageCount), group \(group), spread size \(pagesPerGroup)"
                    )
                }
            }
        }
    }

    func testPaginationKeepsComposedCharactersAndWhitespaceBoundaries() {
        let source = String(repeating: "  Reading 👨‍👩‍👧‍👦 café e\u{301} 继续阅读。\n\n", count: 55)
        let pages = ReaderPagination.pages(from: source, maximumCharacters: 37)

        XCTAssertGreaterThan(pages.count, 10)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 37 })
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
    }

    func testMeasuredPaginationKeepsAllTextAcrossManyPages() {
        let source = String(repeating: "A reader should keep every sentence and its place. 👩🏽‍🚀 继续阅读云端书架。\n\n", count: 120)
        let font = ReaderFont.systemSerif.uiFont(size: 18)
        let pages = ReaderPagination.pages(from: source, width: 280, height: 320, font: font)

        XCTAssertGreaterThan(pages.count, 10)
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
        XCTAssertTrue(pages.allSatisfy { ReaderPagination.measuredHeight(of: $0, width: 280, font: font) <= 320 })
    }

    func testUTF16LocationSurvivesRepaginationAndOddFinalSpread() {
        let source = "Start 👩🏽‍🚀 middle café last page"
        let originalPages = ["Start 👩🏽‍🚀 ", "middle café ", "last page"]
        let offset = ReaderTextLocation.utf16Offset(atGroup: 1, in: originalPages, sourceText: source, pagesPerGroup: 2)
        let repaginatedPages = ["Start 👩🏽‍🚀 middle café", "last page"]

        XCTAssertEqual(offset, (source as NSString).range(of: "last page").location)
        XCTAssertEqual(ReaderTextLocation.groupIndex(forUTF16Offset: offset, in: repaginatedPages, sourceText: source, pagesPerGroup: 2), 0)
        XCTAssertEqual(ReaderPagination.pageGroupCount(pageCount: 3, pagesPerGroup: 2), 2)
        XCTAssertEqual(ReaderTextLocation.utf16Offset(atGroup: 1, in: originalPages, sourceText: source, pagesPerGroup: 2), offset)
    }
}
