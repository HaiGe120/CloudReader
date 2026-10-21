import XCTest
@testable import CloudReaderCore

final class ReaderPaginationPolicyTests: XCTestCase {
    func testSharedAppearanceValuesKeepPreferenceRawValues() {
        XCTAssertEqual(ReaderPageLayout.allCases.map(\.rawValue), ["scroll", "singlePage", "facingPages"])
        XCTAssertEqual(ReaderTheme.allCases.map(\.rawValue), ["system", "light", "sepia", "dark", "custom"])
        XCTAssertEqual(ReaderFont.allCases.map(\.rawValue), ["systemSerif", "systemSans", "rounded", "georgia", "palatino", "avenir", "monospaced"])
    }

    func testPageAndSpreadProgressRoundTripsAtBoundaries() {
        for (pageCount, pagesPerGroup) in [(15, 2), (22, 2), (1, 2), (49, 2), (15, 1), (49, 1)] {
            let groupCount = ReaderPaginationPolicy.pageGroupCount(pageCount: pageCount, pagesPerGroup: pagesPerGroup)
            for group in 0..<groupCount {
                let fraction = ReaderPaginationPolicy.progress(pageGroupIndex: group, pageCount: pageCount, pagesPerGroup: pagesPerGroup)
                XCTAssertEqual(ReaderPaginationPolicy.pageGroupIndex(progress: fraction, pageCount: pageCount, pagesPerGroup: pagesPerGroup), group)
            }
            XCTAssertEqual(ReaderPaginationPolicy.pageGroupIndex(progress: 0, pageCount: pageCount, pagesPerGroup: pagesPerGroup), 0)
            XCTAssertEqual(ReaderPaginationPolicy.pageGroupIndex(progress: 1, pageCount: pageCount, pagesPerGroup: pagesPerGroup), groupCount - 1)
        }
        XCTAssertEqual(ReaderPaginationPolicy.pageGroupCount(pageCount: 15, pagesPerGroup: 2), 8)
        XCTAssertEqual(ReaderPaginationPolicy.progress(pageGroupIndex: 7, pageCount: 15, pagesPerGroup: 2), 14.0 / 15.0, accuracy: 1e-12)
    }

    func testPurePaginationPreservesUnicodeTextAcrossBoundaries() {
        let source = String(repeating: "👨‍👩‍👧‍👦 café e\u{301} 继续阅读。\n\n", count: 60)
        let pages = ReaderPaginationPolicy.pages(from: source, maximumCharacters: 17)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 17 })
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
    }

    func testMeasuredFitPolicyUsesInjectedNativeMeasurementAndHonorsCancellation() {
        let source = String(repeating: "one two three four five ", count: 12)
        let pages = ReaderPaginationPolicy.pages(from: source, fits: { $0.count <= 22 })
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 22 })
        XCTAssertEqual(pages.joined().filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
        XCTAssertTrue(ReaderPaginationPolicy.pages(from: source, fits: { _ in true }, shouldCancel: { true }).isEmpty)
    }
}
