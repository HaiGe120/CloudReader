import AppKit
import CloudReaderCore
import PDFKit
import SwiftUI
@testable import CloudReader
import XCTest

@MainActor
final class MacNativeReaderTests: XCTestCase {
    func testRendererCapabilitiesKeepAppearanceAndCanvasActionsFormatAware() {
        let text = MacReaderBehaviorPolicy.capabilities(for: .txt)
        XCTAssertTrue(text.supportsTypography)
        XCTAssertTrue(text.supportsSelectedTextAI)

        let pdf = MacReaderBehaviorPolicy.capabilities(for: .pdf)
        XCTAssertFalse(pdf.supportsTypography)
        XCTAssertTrue(pdf.supportsSelection)

        let comic = MacReaderBehaviorPolicy.capabilities(for: .cbz)
        XCTAssertFalse(comic.supportsSelection)
        XCTAssertFalse(comic.supportsSelectedTextAI)
        for format in [BookFormat.txt, .pdf, .epub, .mobi, .azw3, .fb2, .cbz, .cbr] {
            XCTAssertTrue(MacReaderBehaviorPolicy.supportsAppearance(for: format), "Expected appearance controls for \(format)")
        }
    }

    func testTextSourceAnchorSurvivesRepagination() {
        let source = "alpha beta gamma delta"
        let originalPages = ["alpha beta", "gamma delta"]
        let repaginatedPages = ["alpha", "beta gamma", "delta"]
        let anchor = try! XCTUnwrap(MacTextSourceAnchoring.sourceOffset(ofPageAt: 1, pages: originalPages, source: source))

        XCTAssertEqual(MacTextSourceAnchoring.pageIndex(containing: anchor, pages: originalPages, source: source), 1)
        XCTAssertEqual(MacTextSourceAnchoring.pageIndex(containing: anchor, pages: repaginatedPages, source: source), 1)
    }

    func testRepeatedTextPagesAnchorToTheirOwnSourceOccurrence() {
        let source = "repeatable passage, repeatable passage"
        let pages = ["repeatable passage", "repeatable passage"]
        let secondOffset = try! XCTUnwrap(MacTextSourceAnchoring.sourceOffset(ofPageAt: 1, pages: pages, source: source))

        XCTAssertEqual(secondOffset, (source as NSString).range(of: "repeatable passage", options: .backwards).location)
        XCTAssertEqual(MacTextSourceAnchoring.pageIndex(containing: secondOffset, pages: pages, source: source), 1)
    }

    func testShellChromeOwnsTXTNavigationAndReleasesInsetWhenHidden() {
        XCTAssertFalse(MacReaderChromePolicy.txtOwnsInlineNavigationFooter)
        XCTAssertTrue(MacReaderChromePolicy.reservesBottomInset(isChromeVisible: true))
        XCTAssertFalse(MacReaderChromePolicy.reservesBottomInset(isChromeVisible: false))
    }

    func testNativeClickFilterRejectsSelectionAndGestureInteractions() {
        XCTAssertTrue(MacNativeClickFilter.shouldToggleChrome(clickCount: 1, dragged: false, hasModifiers: false, selectionChanged: false))
        XCTAssertFalse(MacNativeClickFilter.shouldToggleChrome(clickCount: 2, dragged: false, hasModifiers: false, selectionChanged: false))
        XCTAssertFalse(MacNativeClickFilter.shouldToggleChrome(clickCount: 1, dragged: true, hasModifiers: false, selectionChanged: false))
        XCTAssertFalse(MacNativeClickFilter.shouldToggleChrome(clickCount: 1, dragged: false, hasModifiers: true, selectionChanged: false))
        XCTAssertFalse(MacNativeClickFilter.shouldToggleChrome(clickCount: 1, dragged: false, hasModifiers: false, selectionChanged: true))
    }

    func testPDFLayoutSnapshotPreservesPageAndValidZoom() {
        let snapshot = MacPDFLayoutSnapshot(pageIndex: 5, zoomScale: 1.75)
        XCTAssertEqual(snapshot.restoredPageIndex(pageCount: 10), 5)
        XCTAssertEqual(snapshot.restoredZoomScale, 1.75)

        let clamped = MacPDFLayoutSnapshot(pageIndex: 50, zoomScale: .infinity)
        XCTAssertEqual(clamped.restoredPageIndex(pageCount: 8), 7)
        XCTAssertNil(clamped.restoredZoomScale)
    }

    func testMacReaderUsesSharedSpreadBreakpointAndBoundedMargins() {
        let narrow = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 699, height: 900), pageLayout: .facingPages,
            font: .systemSerif, fontSize: 20
        )
        let wide = ReaderLayoutMetrics.resolve(
            viewport: CGSize(width: 700, height: 900), pageLayout: .facingPages,
            font: .systemSerif, fontSize: 20
        )

        XCTAssertEqual(narrow.effectiveColumnCount, 1)
        XCTAssertEqual(wide.effectiveColumnCount, 2)
        XCTAssertEqual(wide.gutter, ReaderLayoutMetrics.spreadGutter)
        XCTAssertGreaterThanOrEqual(narrow.horizontalMargin, 22)
        XCTAssertLessThanOrEqual(narrow.horizontalMargin, 42)
        XCTAssertEqual(narrow.maximumProseWidth, 780)
    }

    func testPDFLocationSelectionAndZoomSurviveViewportAndChromeChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPDFState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "MacPDFState-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("facingPages", forKey: "reader.pageLayout")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourcePDF = root.appendingPathComponent("native-fixture.pdf")
        try makeSelectablePDF(at: sourcePDF)
        let library = BookLibrary(storageDirectory: root.appendingPathComponent("Library", isDirectory: true), defaults: defaults)
        library.importBooks(from: [sourcePDF])
        let book = try XCTUnwrap(library.books.first(where: { $0.format == .pdf }))

        var presentation: MacReaderPresentation?
        let host = NSHostingView(rootView: NavigationStack {
            MacBookReaderView(book: book)
                .environmentObject(library)
                .defaultAppStorage(defaults)
                .onPreferenceChange(MacReaderPresentationKey.self) { presentation = $0 }
        })
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        let pdfView = try await waitForPDFView(in: host)
        try await waitUntil { presentation?.navigation.pageCount == 3 }
        try await Task.sleep(for: .milliseconds(100))
        let document = try XCTUnwrap(pdfView.document)
        XCTAssertEqual(document.pageCount, 3)
        let targetPage = try XCTUnwrap(document.page(at: 2))
        let targetPageText = try XCTUnwrap(targetPage.string)
        let phraseRange = (targetPageText as NSString).range(of: "selectable passage")
        XCTAssertNotEqual(phraseRange.location, NSNotFound, "The PDF fixture must contain extractable text")
        let selection = try XCTUnwrap(targetPage.selection(for: phraseRange))
        let expectedSelection = try XCTUnwrap(selection.string)
        let target = PDFDestination(page: targetPage, at: CGPoint(x: 74, y: 710))
        pdfView.go(to: target)
        pdfView.scaleFactor = 1.65
        pdfView.setCurrentSelection(selection, animate: false)

        try await Task.sleep(for: .milliseconds(250))
        let expectedPageIndex = try XCTUnwrap(pdfView.currentPage.map { document.index(for: $0) })
        let expectedPoint = try XCTUnwrap(pdfView.currentDestination).point
        XCTAssertEqual(expectedPageIndex, 2)

        window.setContentSize(NSSize(width: 620, height: 620))
        try await waitUntil { [weak pdfView] in
            guard let pdfView, let page = pdfView.currentPage, let currentDocument = pdfView.document else { return false }
            return currentDocument.index(for: page) == expectedPageIndex &&
                abs(pdfView.scaleFactor - 1.65) < 0.02 &&
                abs((pdfView.currentDestination?.point.x ?? .nan) - expectedPoint.x) <= 1 &&
                abs((pdfView.currentDestination?.point.y ?? .nan) - expectedPoint.y) <= 1 &&
                pdfView.currentSelection?.string == expectedSelection
        }
        assertPDFState(pdfView, pageIndex: expectedPageIndex, destinationPoint: expectedPoint, selection: expectedSelection)

        sendChromeToggle(to: window)
        try await waitUntil { presentation?.chromeVisible == false }
        assertPDFState(pdfView, pageIndex: expectedPageIndex, destinationPoint: expectedPoint, selection: expectedSelection)

        sendChromeToggle(to: window)
        try await waitUntil { presentation?.chromeVisible == true }
        assertPDFState(pdfView, pageIndex: expectedPageIndex, destinationPoint: expectedPoint, selection: expectedSelection)
    }

    private func makeSelectablePDF(at url: URL) throws {
        let document = PDFDocument()
        for index in 0..<3 {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            textView.string = "Fixture page \(index + 1)\n\nA selectable passage must survive native PDF layout changes."
            textView.font = NSFont.systemFont(ofSize: 22)
            let pagePDF = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
            document.insert(try XCTUnwrap(pagePDF.page(at: 0)), at: index)
        }
        XCTAssertTrue(document.write(to: url))
    }

    private func waitForPDFView(in view: NSView, timeout: TimeInterval = 5) async throws -> PDFView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = findPDFView(in: view), found.document?.pageCount == 3 { return found }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(30))
        }
        return try XCTUnwrap(findPDFView(in: view), "Reader did not attach a PDFKit view")
    }

    private func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Timed out waiting for the PDF reader state", file: file, line: line)
    }

    private func assertPDFState(_ view: PDFView, pageIndex: Int, destinationPoint: CGPoint, selection: String, file: StaticString = #filePath, line: UInt = #line) {
        let currentPageIndex = view.currentPage.flatMap { view.document?.index(for: $0) }
        XCTAssertEqual(currentPageIndex, pageIndex, file: file, line: line)
        let currentPoint = view.currentDestination?.point
        XCTAssertEqual(currentPoint?.x ?? .nan, destinationPoint.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(currentPoint?.y ?? .nan, destinationPoint.y, accuracy: 1, file: file, line: line)
        XCTAssertEqual(view.scaleFactor, 1.65, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(view.currentSelection?.string, selection, file: file, line: line)
    }

    private func findPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView { return pdfView }
        for child in view.subviews {
            if let found = findPDFView(in: child) { return found }
        }
        return nil
    }

    private func findAccessibilityView(in window: NSWindow, identifier: String) -> NSAccessibilityProtocol? {
        var pending: [AnyObject] = [window]
        if let content = window.contentView { pending.append(content) }
        pending.append(contentsOf: window.toolbar?.items.compactMap(\.view) ?? [])
        var visited = Set<ObjectIdentifier>()
        while visited.count < 2_000, let object = pending.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let accessible = object as? NSAccessibilityProtocol {
                if accessible.accessibilityIdentifier() == identifier { return accessible }
                let children = accessible.accessibilityChildren() ?? []
                if !children.isEmpty { pending.append(contentsOf: children.map { $0 as AnyObject }) }
                else if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            }
        }
        return nil
    }

    private func sendChromeToggle(to window: NSWindow) {
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15) else {
            XCTFail("Could not construct chrome toggle key events")
            return
        }
        XCTAssertTrue(window.performKeyEquivalent(with: down), "Reader keyboard shortcut must be handled")
        window.sendEvent(up)
    }
}
