import CloudReaderCore
import SwiftUI
import XCTest
@testable import CloudReader

final class EPUBWebReaderTests: XCTestCase {
    func testLayoutMetricsUseMeasuredViewportForSpreadBreakpointAndMargins() {
        let narrow = ReaderLayoutMetrics.resolve(viewport: CGSize(width: 699, height: 900), pageLayout: .facingPages, font: .georgia, fontSize: 20)
        let wide = ReaderLayoutMetrics.resolve(viewport: CGSize(width: 700, height: 900), pageLayout: .facingPages, font: .georgia, fontSize: 20)
        let compact = ReaderLayoutMetrics.resolve(viewport: CGSize(width: 320, height: 700), pageLayout: .scroll, font: .georgia, fontSize: 20)
        let desktop = ReaderLayoutMetrics.resolve(viewport: CGSize(width: 1200, height: 900), pageLayout: .scroll, font: .georgia, fontSize: 20)

        XCTAssertEqual(narrow.effectiveColumnCount, 1)
        XCTAssertEqual(wide.effectiveColumnCount, 2)
        XCTAssertEqual(wide.gutter, 28)
        XCTAssertEqual(compact.horizontalMargin, 22)
        XCTAssertEqual(desktop.horizontalMargin, 42)
        XCTAssertEqual(desktop.maximumProseWidth, 780)
    }

    func testEPUBNavigationPolicySharesChapterAndDocumentClassification() {
        let chapters = [
            EPUBChapter(path: "Text/one.xhtml", title: "One"),
            EPUBChapter(path: "Text/two.xhtml", title: "Two")
        ]
        let mediaTypes = ["Notes/endnote": "application/xhtml+xml", "Images/cover": "image/png"]

        XCTAssertEqual(
            EPUBNavigationPolicy.destination(
                path: "Text/two.xhtml", fragment: "section-2", currentPath: "Text/one.xhtml",
                chapters: chapters, mediaTypes: mediaTypes
            ),
            .chapter(index: 1, fragment: "section-2")
        )
        XCTAssertEqual(
            EPUBNavigationPolicy.destination(
                path: "Notes/endnote", fragment: "note-1", currentPath: "Text/one.xhtml",
                chapters: chapters, mediaTypes: mediaTypes
            ),
            .document(path: "Notes/endnote", fragment: "note-1")
        )
        XCTAssertNil(EPUBNavigationPolicy.destination(
            path: "Text/one.xhtml", fragment: "same-chapter", currentPath: "Text/one.xhtml",
            chapters: chapters, mediaTypes: mediaTypes
        ))
        XCTAssertNil(EPUBNavigationPolicy.destination(
            path: "Images/cover", fragment: nil, currentPath: "Text/one.xhtml",
            chapters: chapters, mediaTypes: mediaTypes
        ))
    }
}
