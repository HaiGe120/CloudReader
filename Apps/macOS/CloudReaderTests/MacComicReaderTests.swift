import AppKit
import CloudReaderCore
import XCTest
@testable import CloudReader

@MainActor
final class MacComicReaderTests: XCTestCase {
    func testRestoredFacingSpreadAndOddFinalPageHaveNoPhantomNavigation() {
        let state = MacComicReaderState()

        state.restore(progress: 1, pageCount: 5, columns: 2)

        XCTAssertEqual(state.firstPage, 4)
        XCTAssertEqual(state.scrollPosition, 1)
        XCTAssertFalse(state.move(by: 1, pageCount: 5, columns: 2))
        XCTAssertEqual(state.firstPage, 4)
        XCTAssertTrue(state.move(by: -1, pageCount: 5, columns: 2))
        XCTAssertEqual(state.firstPage, 2)
    }

    func testRequestIsConsumedOnceAndSeekClampsAndAligns() {
        let state = MacComicReaderState()
        state.restore(progress: 0, pageCount: 7, columns: 2)
        let request = ReaderNavigationRequest(command: .seek(0.99))

        XCTAssertTrue(state.consume(request, pageCount: 7, columns: 2))
        XCTAssertEqual(state.firstPage, 6)
        XCTAssertFalse(state.consume(request, pageCount: 7, columns: 2))
        XCTAssertEqual(state.firstPage, 6)

        let invalid = ReaderNavigationRequest(command: .seek(.nan))
        XCTAssertTrue(state.consume(invalid, pageCount: 7, columns: 2))
        XCTAssertEqual(state.firstPage, 0)
        XCTAssertEqual(state.scrollPosition, 0)
    }

    func testSinglePageProgressAndZoomBounds() {
        let state = MacComicReaderState()
        state.restore(progress: 0.75, pageCount: 4, columns: 1)
        XCTAssertEqual(state.firstPage, 2)
        XCTAssertEqual(state.scrollPosition, 2.0 / 3.0, accuracy: 0.000_001)

        state.setZoom(8, pan: CGSize(width: 80, height: -20))
        XCTAssertEqual(state.zoomScale, 5)
        XCTAssertEqual(state.panOffset, CGSize(width: 80, height: -20))
        state.setZoom(0)
        XCTAssertEqual(state.zoomScale, 1)
        XCTAssertEqual(state.panOffset, .zero)
    }

    func testCanvasPagesOnceForTrackpadGestureAndItsMomentumTail() {
        let canvas = MacComicCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var pageDeltas: [Int] = []
        canvas.configure(urls: [], background: .clear, maxPixel: 800, pagingEnabled: true,
                         zoomScale: 1, panOffset: .zero,
                         onPage: { pageDeltas.append($0) }, onZoom: { _, _ in }, onTap: {})

        canvas.handleWheel(deltaX: -12, precise: true, phase: .began, momentumPhase: [])
        canvas.handleWheel(deltaX: -42, precise: true, phase: .changed, momentumPhase: [])
        canvas.handleWheel(deltaX: -640, precise: true, phase: .changed, momentumPhase: [])
        canvas.handleWheel(deltaX: 0, precise: true, phase: .ended, momentumPhase: [])
        canvas.handleWheel(deltaX: -60, precise: true, phase: [], momentumPhase: .began)
        canvas.handleWheel(deltaX: -150, precise: true, phase: [], momentumPhase: .changed)
        canvas.handleWheel(deltaX: 0, precise: true, phase: [], momentumPhase: .ended)

        XCTAssertEqual(pageDeltas, [1], "A natural leftward content scroll must advance one page or spread.")
    }

    func testCanvasCoalescesDiscreteWheelAndKeepsVerticalScrollModeNative() {
        let canvas = MacComicCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var pageDeltas: [Int] = []
        canvas.configure(urls: [], background: .clear, maxPixel: 800, pagingEnabled: true,
                         zoomScale: 1, panOffset: .zero,
                         onPage: { pageDeltas.append($0) }, onZoom: { _, _ in }, onTap: {})

        canvas.handleWheel(deltaX: -1, precise: false, phase: [], momentumPhase: [])
        canvas.handleWheel(deltaX: -1, precise: false, phase: [], momentumPhase: [])
        canvas.finishDiscreteWheelGesture()
        XCTAssertEqual(pageDeltas, [1])

        canvas.configure(urls: [], background: .clear, maxPixel: 800, pagingEnabled: false,
                         zoomScale: 1, panOffset: .zero,
                         onPage: { pageDeltas.append($0) }, onZoom: { _, _ in }, onTap: {})
        canvas.handleWheel(deltaX: -700, precise: true, phase: .began, momentumPhase: [])
        XCTAssertEqual(pageDeltas, [1], "Vertical reading mode should leave wheel handling to its native scroll view.")
    }

    func testZoomedCanvasPublishesPanForSubsequentSwiftUIUpdates() {
        let canvas = MacComicCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var latestZoom: CGFloat = 1
        var latestPan = CGSize.zero
        canvas.configure(urls: [], background: .clear, maxPixel: 800, pagingEnabled: true,
                         zoomScale: 2, panOffset: .zero,
                         onPage: { _ in }, onZoom: { latestZoom = $0; latestPan = $1 }, onTap: {})

        canvas.panBy(deltaX: -35, deltaY: 22)

        XCTAssertEqual(latestZoom, 2)
        XCTAssertEqual(latestPan, CGSize(width: -35, height: 22))
    }
}
