import AppKit
import CloudReaderCore
import SwiftUI
import WebKit
import ZIPFoundation
import XCTest
@testable import CloudReader

@MainActor
final class MacReflowReaderTests: XCTestCase {
    func testReflowRendererLoadsInIsolatedWebKitAndKeepsSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEPUBReflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prose = String(repeating: "A sample passage for reflow testing. ", count: 900)
        let html = """
        <!doctype html><html><head><script>window.publisherScriptRan = true;</script></head>
        <body><h1>Reflow fixture</h1><p id="passage" style="width:120px">\(prose)</p><strong id="semantic-bold">Bold</strong>
        <strong><span id="nested-bold">Nested bold</span></strong>
        <a href="note.xhtml#back">Footnote</a></body></html>
        """
        try Data(html.utf8).write(to: root.appendingPathComponent("chapter.xhtml"))
        try Data("<!doctype html><p id='back'>Footnote note text</p><a href='chapter.xhtml#passage'>Return to text</a>".utf8).write(to: root.appendingPathComponent("note.xhtml"))

        let publication = EPUBPublication(
            rootURL: root,
            title: "Reflow fixture",
            chapters: [EPUBChapter(path: "chapter.xhtml", title: "Chapter 1")],
            mediaTypes: ["chapter.xhtml": "application/xhtml+xml", "note.xhtml": "application/xhtml+xml"]
        )
        let loaded = expectation(description: "reader completes initial configure")
        let located = expectation(description: "reader reports its rendered location")
        let tapped = expectation(description: "one clean content tap reaches the shell")
        var nextLoadExpectation: XCTestExpectation? = loaded
        var didTapContent = false
        var reportedPageCount = 0
        var horizontalTurn: XCTestExpectation?
        var reflowed: XCTestExpectation?
        let state = MacReflowHarnessState()
        let host = NSHostingView(rootView: MacReflowHarness(
            publication: publication, state: state,
            onLoaded: { nextLoadExpectation?.fulfill(); nextLoadExpectation = nil },
            onError: { XCTFail($0) },
            onContentTap: { if !didTapContent { didTapContent = true; tapped.fulfill() } },
            onNavigationState: { page, pages, _ in
                if let pages, pages > 1, reportedPageCount == 0 { reportedPageCount = pages; located.fulfill() }
                if let page, page == 3 { horizontalTurn?.fulfill(); horizontalTurn = nil }
                if page != nil { reflowed?.fulfill(); reflowed = nil }
            }
        ).frame(width: 800, height: 620))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            if let webView = findWebView(in: host) {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.removeFromSuperview()
            }
            window.contentView = nil
            window.close()
        }

        await fulfillment(of: [loaded, located], timeout: 15)
        let webView = try XCTUnwrap(findWebView(in: host))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const p=document.getElementById('passage'), range=document.createRange();
          range.selectNodeContents(p); const selection=getSelection(); selection.removeAllRanges(); selection.addRange(range);
          return { publisher: typeof window.publisherScriptRan, injected: typeof window.cloudReader,
            viewport: document.querySelector('meta[name=viewport]')?.content,
            family: getComputedStyle(document.body).fontFamily,
            bold: getComputedStyle(document.getElementById('semantic-bold')).fontWeight,
            nestedBold: getComputedStyle(document.getElementById('nested-bold')).fontWeight,
            proseWidth: parseFloat(getComputedStyle(p).width),
            selected: String(selection).length };
        })()
        """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["publisher"] as? String, "undefined", "Publisher scripts must remain disabled")
        XCTAssertEqual(values["injected"] as? String, "undefined", "Reader internals must stay out of the publisher page world")
        let isolatedConfigure: Any? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript("return typeof window.cloudReader.configure;", arguments: [:], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertEqual(isolatedConfigure as? String, "function", "Reader script should remain available in its isolated client world")
        XCTAssertEqual(values["viewport"] as? String, "width=device-width, initial-scale=1")
        XCTAssertTrue((values["family"] as? String)?.contains("Georgia") == true)
        XCTAssertEqual(values["bold"] as? String, "600")
        XCTAssertEqual(values["nestedBold"] as? String, "600", "Nested semantic bold must survive inherited weight normalization")
        XCTAssertGreaterThan(values["proseWidth"] as? Double ?? 0, 120, "Publisher fixed paragraph widths must not narrow app prose")
        XCTAssertGreaterThan(values["selected"] as? Int ?? 0, 100, "WebKit selection must remain available")
        XCTAssertGreaterThan(reportedPageCount, 1, "The paged renderer should report multiple pages")

        let turned = expectation(description: "a native horizontal wheel event snaps exactly one two-page spread")
        let turnDispatched = expectation(description: "Mac wheel gesture dispatches one page-turn request")
        horizontalTurn = turned
        let readerWebView = try XCTUnwrap(webView as? MacReaderWKWebView)
        XCTAssertNotNil(readerWebView.onPageTurn)
        let originalTurn = readerWebView.onPageTurn
        var dispatchCount = 0
        readerWebView.onPageTurn = { direction in
            dispatchCount += 1
            originalTurn?(direction)
            if dispatchCount == 1 { turnDispatched.fulfill() }
        }
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -3, wheel3: 0))
        cgEvent.location = CGPoint(x: 200, y: 200)
        let wheelEvent = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertGreaterThan(abs(wheelEvent.scrollingDeltaX), abs(wheelEvent.scrollingDeltaY), "Fixture event must represent a horizontal wheel gesture")
        readerWebView.scrollWheel(with: wheelEvent)
        await fulfillment(of: [turnDispatched, turned], timeout: 5)
        XCTAssertEqual(dispatchCount, 1, "One wheel gesture must request one spread turn")

        let measuredOffset = try await webView.evaluateJavaScript("document.caretRangeFromPoint(60, 24).startOffset")
        let offset = try XCTUnwrap(measuredOffset as? Int)
        XCTAssertGreaterThan(offset, 100, "The reflow check must start beyond the first spread")
        let resized = expectation(description: "typography change restores the visible source passage")
        reflowed = resized
        state.fontSize = 24
        await fulfillment(of: [resized], timeout: 5)
        let anchorVisible = try await webView.evaluateJavaScript("(() => {const r=document.createRange(),n=document.getElementById('passage').firstChild;r.setStart(n,\(offset));r.setEnd(n,\(offset + 1));const b=r.getBoundingClientRect();return b.right>0&&b.left<innerWidth&&b.bottom>0&&b.top<innerHeight;})()") as? Bool
        XCTAssertEqual(anchorVisible, true, "The same source passage must stay visible after font reflow")

        _ = try await webView.evaluateJavaScript("getSelection().removeAllRanges(); document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, detail:1, clientX:180, clientY:180}));")
        await fulfillment(of: [tapped], timeout: 5)
        XCTAssertTrue(didTapContent)

        let noteLoaded = expectation(description: "internal footnote opens in the restricted reader")
        nextLoadExpectation = noteLoaded
        _ = try await webView.evaluateJavaScript("document.querySelector('a').click()")
        await fulfillment(of: [noteLoaded], timeout: 10)
        XCTAssertTrue(webView.url?.path.hasSuffix("note.xhtml") == true)

        state.chromeVisible = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(findWebView(in: host)?.url?.path.hasSuffix("note.xhtml") == true, "Shell appearance updates must preserve an open footnote")

        let backlinkLoaded = expectation(description: "footnote backlink returns to the spine chapter")
        nextLoadExpectation = backlinkLoaded
        _ = try await XCTUnwrap(findWebView(in: host)).evaluateJavaScript("document.querySelector('a').click()")
        await fulfillment(of: [backlinkLoaded], timeout: 10)
        XCTAssertTrue(findWebView(in: host)?.url?.path.hasSuffix("chapter.xhtml") == true)
    }

    func testComposedMacReaderPublishesReadyAndPageStateForNestedChapter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEPUBComposed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookID = UUID()
        let cacheRoot = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("EPUB", isDirectory: true)
        let cache = cacheRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let archiveURL = root.appendingPathComponent("fixture.epub")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let prose = String(repeating: "Nested package path should still report the visible page. ", count: 500)
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
            ("OEBPS/package.opf", "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Composed fixture</dc:title></metadata><manifest><item id=\"chapter\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"),
            ("OEBPS/one.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title></head><body><h1>Nested chapter</h1><p>\(prose)</p></body></html>")
        ]
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: path == "mimetype" ? .none : .deflate) { position, count in
                data.subdata(in: Int(position)..<(Int(position) + count))
            }
        }

        for width: CGFloat in [699, 700] {
        let located = expectation(description: "composed renderer publishes actual page state at \(width) points")
        var locationOnce = false
        let reader = MacEPUBBookReader(
            bookID: bookID, url: archiveURL, progress: 0, pageLayoutRaw: "facingPages",
            fontRaw: "georgia", fontSize: 20, background: Color(nsColor: .textBackgroundColor),
            foreground: Color(nsColor: .labelColor), onProgressChanged: { _ in }, onSelectionChanged: { _ in },
            onNavigationStateChanged: { state in
                let expectedColumns = width < 700 ? 1 : 2
                if state.pageCount ?? 0 > 1, state.pageRange?.count == expectedColumns, !locationOnce {
                    locationOnce = true; located.fulfill()
                }
            }
        )
        let host = NSHostingView(rootView: reader.frame(width: width, height: 680))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            findWebView(in: host)?.stopLoading()
            findWebView(in: host)?.navigationDelegate = nil
            findWebView(in: host)?.removeFromSuperview()
            window.contentView = nil
            window.close()
        }
        await fulfillment(of: [located], timeout: 20)
        }
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = findWebView(in: child) { return found }
        }
        return nil
    }
}

@MainActor
private final class MacReflowHarnessState: ObservableObject {
    @Published var chapter = 0
    @Published var fragment: String?
    @Published var navigationID = UUID()
    @Published var chromeVisible = true
    @Published var fontSize = 20.0
}

private struct MacReflowHarness: View {
    let publication: EPUBPublication
    @ObservedObject var state: MacReflowHarnessState
    let onLoaded: () -> Void
    let onError: (String) -> Void
    let onContentTap: () -> Void
    let onNavigationState: (Int?, Int?, Double) -> Void

    var body: some View {
        MacEPUBWebView(
            publication: publication, chapter: state.chapter, initialProgress: 0,
            pageLayoutRaw: "facingPages", fontRaw: "georgia", fontSize: state.fontSize,
            background: Color(nsColor: .textBackgroundColor), foreground: Color(nsColor: .labelColor),
            navigationID: state.navigationID, targetFragment: state.fragment, viewportSize: CGSize(width: 800, height: 620),
            isChromeVisible: state.chromeVisible, onProgress: { _ in }, onSelection: { _ in },
            onNavigate: { chapter, fragment in
                state.chapter = chapter
                state.fragment = fragment
                state.navigationID = UUID()
            }, onChapterBoundary: { _ in }, onLoaded: onLoaded, onError: onError,
            onContentTap: onContentTap, onNavigationState: onNavigationState
        )
    }
}
