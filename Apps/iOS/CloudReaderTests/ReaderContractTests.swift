import CloudReaderCore
import XCTest
@testable import CloudReader

final class ReaderContractTests: XCTestCase {
    func testSpreadBreakpointUsesMeasuredReaderWidth() {
        let below = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 699, height: 900),
            pageLayout: .facingPages,
            font: .systemSerif,
            fontSize: 20
        )
        let at = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 700, height: 900),
            pageLayout: .facingPages,
            font: .systemSerif,
            fontSize: 20
        )
        let scrolling = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 1_200, height: 900),
            pageLayout: .scroll,
            font: .systemSerif,
            fontSize: 20
        )

        XCTAssertEqual(below.effectiveColumnCount, 1)
        XCTAssertEqual(at.effectiveColumnCount, 2)
        XCTAssertEqual(at.gutter, 28)
        XCTAssertEqual(scrolling.effectiveColumnCount, 1)
        XCTAssertEqual(scrolling.maximumProseWidth, 780)
    }

    func testAdaptiveMarginsClampAtBothEnds() {
        let narrow = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 320, height: 700),
            pageLayout: .scroll,
            font: .systemSerif,
            fontSize: 20
        )
        let medium = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 800, height: 900),
            pageLayout: .scroll,
            font: .systemSerif,
            fontSize: 20
        )
        let wide = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 1_500, height: 900),
            pageLayout: .scroll,
            font: .systemSerif,
            fontSize: 20
        )

        XCTAssertEqual(narrow.horizontalMargin, 22)
        XCTAssertEqual(medium.horizontalMargin, 36)
        XCTAssertEqual(wide.horizontalMargin, 42)
    }
}
