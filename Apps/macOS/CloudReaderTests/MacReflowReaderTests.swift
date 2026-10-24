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

    func testPositionNavigationAndChromeDoNotRepaginateTheChapter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEPUBNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prose = String(repeating: "A page turn keeps the existing text layout intact. ", count: 900)
        try Data("<!doctype html><html style='scroll-behavior:smooth'><body><p>\(prose)</p></body></html>".utf8)
            .write(to: root.appendingPathComponent("one.xhtml"))
        let publication = EPUBPublication(rootURL: root, title: "Navigation fixture",
            chapters: [EPUBChapter(path: "one.xhtml", title: "One")], mediaTypes: ["one.xhtml": "application/xhtml+xml"])
        let state = MacReflowHarnessState()
        var loads = 0
        var latestProgress = 0.0
        var latestPage = 0
        var latestCount = 0
        let host = NSHostingView(rootView: MacReflowHarness(publication: publication, state: state,
            onLoaded: { loads += 1 }, onError: { XCTFail($0) }, onContentTap: {},
            onNavigationState: { page, count, progress in
                latestPage = page ?? 0; latestCount = count ?? 0; latestProgress = progress
            }).frame(width: 800, height: 620))
        let window = makeWindow(host)
        defer { closeWindow(window, host: host) }
        let ready = try await waitUntil { loads == 1 && latestCount > 2 }
        XCTAssertTrue(ready)
        let webView = try XCTUnwrap(findWebView(in: host))
        _ = try await webView.evaluateJavaScript("""
        window.readerStyleMutations = 0;
        new MutationObserver(changes => { window.readerStyleMutations += changes.length; })
          .observe(document.getElementById('cloudreader-style'), {childList:true, characterData:true, subtree:true});
        """)
        let pageCount = latestCount
        state.progress = 0.6
        state.navigationID = UUID()
        let turned = try await waitUntil { latestPage > 1 && abs(latestProgress - 0.6) < 0.05 }
        XCTAssertTrue(turned, "An explicit page jump must reach the requested spread even with publisher smooth scrolling")
        XCTAssertEqual(latestCount, pageCount)
        let pageAfterTurn = latestPage
        state.chromeVisible = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(latestPage, pageAfterTurn, "Chrome updates at a fixed viewport must keep the current spread")
        let mutations = try await webView.evaluateJavaScript("window.readerStyleMutations") as? Int
        XCTAssertEqual(mutations, 0, "Position-only navigation and chrome state must not replace the stylesheet")
    }

    func testChapterTransitionHoldsPreviousPageUntilLatestDestinationIsReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEPUBTransition-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prose = String(repeating: "The next chapter waits for its final reading position. ", count: 1_000)
        for name in ["one", "two"] {
            try Data("<!doctype html><html><head><style>body{background:magenta;font-size:64px;visibility:visible}</style></head><body><h1>\(name)</h1><p>\(prose)</p></body></html>".utf8)
                .write(to: root.appendingPathComponent("\(name).xhtml"))
        }
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='800' height='620'><rect width='800' height='620' fill='magenta'/><text x='30' y='70' font-size='40'>SVG chapter</text></svg>".utf8)
            .write(to: root.appendingPathComponent("three.svg"))
        let publication = EPUBPublication(rootURL: root, title: "Chapter fixture",
            chapters: [EPUBChapter(path: "one.xhtml", title: "One"), EPUBChapter(path: "two.xhtml", title: "Two"),
                       EPUBChapter(path: "three.svg", title: "Three")],
            mediaTypes: ["one.xhtml": "application/xhtml+xml", "two.xhtml": "application/xhtml+xml", "three.svg": "image/svg+xml"])
        let state = MacReflowHarnessState()
        var loads = 0
        var latestProgress = 0.0
        let host = NSHostingView(rootView: MacReflowHarness(publication: publication, state: state,
            onLoaded: { loads += 1 }, onError: { XCTFail($0) }, onContentTap: {},
            onNavigationState: { _, _, progress in latestProgress = progress }).frame(width: 800, height: 620))
        let window = makeWindow(host)
        defer { closeWindow(window, host: host) }
        let ready = try await waitUntil { loads == 1 }
        XCTAssertTrue(ready)
        let webView = try XCTUnwrap(findWebView(in: host))
        webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        const configureChapter = window.cloudReader.configure;
        window.cloudReader.configure = async (...args) => {
          window.chapterConfigurationStarted = true;
          window.chapterOpacityBeforeLayout = getComputedStyle(document.documentElement).opacity;
          await new Promise(resolve => setTimeout(resolve, 250));
          return await configureChapter(...args);
        };
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        state.chapter = 1
        state.progress = 0.25
        state.navigationID = UUID()
        let configuring = try await waitUntil {
            guard webView.url?.lastPathComponent == "two.xhtml" else { return false }
            return (try? await self.clientValue(webView, "return window.chapterConfigurationStarted === true;")) as? Bool == true
        }
        XCTAssertTrue(configuring)
        let opacity = try await clientValue(webView, "return window.chapterOpacityBeforeLayout;") as? String
        XCTAssertEqual(opacity, "0", "A chapter must not paint publisher styling, even with explicitly visible descendants")
        XCTAssertTrue(webView.subviews.contains { $0.identifier?.rawValue == "reader.navigationSnapshot" },
            "The outgoing page must cover the destination until its layout is ready")
        state.progress = 0.8
        state.navigationID = UUID()
        let destinationReady = try await waitUntil { loads == 2 && abs(latestProgress - 0.8) < 0.05 }
        XCTAssertTrue(destinationReady, "The latest jump received during chapter preparation must win")
        XCTAssertTrue(findWebView(in: host) === webView, "Chapter changes must reuse the native reader")
        XCTAssertFalse(webView.subviews.contains { $0.identifier?.rawValue == "reader.navigationSnapshot" })
        let revealed = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).opacity") as? String
        XCTAssertEqual(revealed, "1")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(loads, 2, "One chapter transition must only publish ready once")
        XCTAssertEqual(latestProgress, 0.8, accuracy: 0.05, "A stale restoration must not rewind the chapter")

        state.chapter = 2
        state.progress = 0
        state.navigationID = UUID()
        let configuringSVG = try await waitUntil {
            guard webView.url?.lastPathComponent == "three.svg" else { return false }
            return (try? await self.clientValue(webView, "return window.chapterConfigurationStarted === true;")) as? Bool == true
        }
        XCTAssertTrue(configuringSVG)
        let svgOpacity = try await clientValue(webView, "return window.chapterOpacityBeforeLayout;") as? String
        XCTAssertEqual(svgOpacity, "0", "SVG chapters need the same first-paint gate as HTML chapters")
        let svgReady = try await waitUntil { loads == 3 }
        XCTAssertTrue(svgReady)
        let svgRevealed = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).opacity") as? String
        XCTAssertEqual(svgRevealed, "1")
    }

    func testSpreadOriginsRemainAlignedThroughLongChaptersAndOddLastPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEPUBAlignment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var fixtures: [(String, EPUBPublication, Int?)] = []
        for (name, count, images) in [("even", 8, false), ("odd", 7, false), ("images", 7, true)] {
            let sections = (1...count).map { page in
                let content = images
                    ? "<img src='data:image/svg+xml,%3Csvg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"300\"%3E%3Crect width=\"240\" height=\"300\" fill=\"teal\"/%3E%3C/svg%3E'/>"
                    : "<h2>第\(page)页</h2><p>用中文段落验证连续翻页时的列对齐。每次翻页，文字都应该完整地留在页面内。</p><blockquote>阅读位置应保持稳定，不能随着章节向左或向右漂移。</blockquote>"
                return "<section id='page-\(page)'>\(content)</section>"
            }.joined()
            let html = "<!doctype html><html><head><style>section{break-before:column}section:first-child{break-before:auto}</style></head><body>\(sections)</body></html>"
            let path = "\(name).xhtml"
            try Data(html.utf8).write(to: root.appendingPathComponent(path))
            fixtures.append((name, EPUBPublication(rootURL: root, title: name,
                chapters: [EPUBChapter(path: path, title: name)], mediaTypes: [path: "application/xhtml+xml"]), count))
        }
        // Optional diagnostics use a deliberately staged copy, never a personal
        // library/store. Generated fixtures above remain the portable regression.
        if let localRoot = ProcessInfo.processInfo.environment["CLOUDREADER_EPUB_ALIGNMENT_ROOT"],
           let chapterPath = ProcessInfo.processInfo.environment["CLOUDREADER_EPUB_ALIGNMENT_CHAPTER"] {
            fixtures.append(("staged-publication", EPUBPublication(rootURL: URL(fileURLWithPath: localRoot), title: "Staged chapter",
                chapters: [EPUBChapter(path: chapterPath, title: "Staged chapter")], mediaTypes: [chapterPath: "text/html"]), nil))
        }

        for (name, publication, expectedCount) in fixtures {
            let state = MacReflowHarnessState()
            var loads = 0, reports = 0, latestPage = 0, latestCount = 0
            var boundaries: [Int] = []
            let host = NSHostingView(rootView: MacReflowHarness(publication: publication, state: state,
                onLoaded: { loads += 1 }, onError: { XCTFail($0) }, onContentTap: {},
                onNavigationState: { page, count, _ in
                    reports += 1; latestPage = page ?? 0; latestCount = count ?? 0
                }, onChapterBoundary: { boundaries.append($0) }))
            let window = makeWindow(host)
            defer { closeWindow(window, host: host) }
            let ready = try await waitUntil { loads == 1 && reports > 0 }
            XCTAssertTrue(ready, name)
            let webView = try XCTUnwrap(findWebView(in: host))
            if let expectedCount { XCTAssertEqual(latestCount, expectedCount, name) }
            try await Task.sleep(for: .milliseconds(200))
            for spread in 1...3 {
                let before = reports
                _ = try await clientValue(webView, "window.cloudReader.turnPage(1);")
                let turned = try await waitUntil { reports > before }
                XCTAssertTrue(turned, name)
                try await assertSpreadOrigin(webView, index: spread, name: "\(name), turn \(spread)")
                XCTAssertEqual(latestPage, spread * 2 + 1, name)
            }
            if name == "staged-publication" {
                let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                    webView.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? EPUBError.invalidBook) }
                    }
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Staged EPUB pages 7–8 aligned"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let beforeKey = reports
            _ = try await webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft', bubbles:true}));")
            let keyed = try await waitUntil { reports > beforeKey }
            XCTAssertTrue(keyed, name)
            try await assertSpreadOrigin(webView, index: 2, name: "\(name), keyboard")

            let beforeEnd = reports
            state.progress = 1
            state.navigationID = UUID()
            let reachedEnd = try await waitUntil { reports > beforeEnd }
            XCTAssertTrue(reachedEnd, name)
            let lastSpread = (latestCount - 1) / 2
            try await assertSpreadOrigin(webView, index: lastSpread, name: "\(name), final spread")
            let beforeBoundary = boundaries.count
            _ = try await clientValue(webView, "window.cloudReader.turnPage(1);")
            let ended = try await waitUntil { boundaries.count > beforeBoundary }
            XCTAssertTrue(ended, "\(name) must report the chapter boundary at its final spread")

            if expectedCount != nil {
                let beforeFragment = reports
                state.fragment = "page-6"
                state.navigationID = UUID()
                let anchored = try await waitUntil { reports > beforeFragment }
                XCTAssertTrue(anchored, name)
                try await assertSpreadOrigin(webView, index: 2, name: "\(name), second-column fragment")
                XCTAssertEqual(latestPage, 5, name)
            }
            let beforeResize = reports
            state.viewportSize = CGSize(width: 799.5, height: 600)
            window.setContentSize(state.viewportSize)
            host.frame.size = state.viewportSize
            let resized = try await waitUntil { reports > beforeResize }
            XCTAssertTrue(resized, name)
            try await assertSpreadOrigin(webView, index: nil, name: "\(name), fractional resize")
            if let expectedCount { XCTAssertEqual(latestCount, expectedCount, name) }

            let beforeSingle = reports
            state.pageLayoutRaw = "singlePage"
            let single = try await waitUntil { reports > beforeSingle }
            XCTAssertTrue(single, name)
            try await assertSpreadOrigin(webView, index: nil, columns: 1, name: "\(name), single page")
            if name == "images" {
                let beforeLateContent = reports
                _ = try await webView.evaluateJavaScript("const last=document.body.lastElementChild; document.body.append(last.cloneNode(true), last.cloneNode(true));")
                state.progress = 1
                state.fragment = nil
                state.navigationID = UUID()
                let updated = try await waitUntil { reports > beforeLateContent && latestCount == 9 && latestPage == 9 }
                XCTAssertTrue(updated)
                XCTAssertEqual(latestCount, 9, "Late media layout must invalidate the cached content count")
                try await assertSpreadOrigin(webView, index: 8, columns: 1, name: "late media layout")
            }
        }
    }

    private func assertSpreadOrigin(_ webView: WKWebView, index: Int?, columns: Int = 2, name: String) async throws {
        let values = try await webView.evaluateJavaScript("""
        (() => {const body=document.body, style=getComputedStyle(body), columns=\(columns);
          const width=body.getBoundingClientRect().width, gap=parseFloat(style.columnGap)||0;
          return {x:scrollX, stride:width+gap, viewport:innerWidth};})()
        """) as? [String: Any]
        let geometry = try XCTUnwrap(values)
        let x = try XCTUnwrap(geometry["x"] as? Double)
        let stride = try XCTUnwrap(geometry["stride"] as? Double)
        let target = Double(index ?? Int((x / stride).rounded())) * stride
        XCTAssertEqual(x, target, accuracy: 1, "\(name): physical column origins must align with the viewport")
    }

    private func clientValue(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) {
                continuation.resume(with: $0.map { $0 as Any? })
            }
        }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try await condition()
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func closeWindow(_ window: NSWindow, host: NSView) {
        findWebView(in: host)?.stopLoading()
        findWebView(in: host)?.navigationDelegate = nil
        findWebView(in: host)?.removeFromSuperview()
        window.contentView = nil
        window.close()
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
    @Published var progress = 0.0
    @Published var fragment: String?
    @Published var navigationID = UUID()
    @Published var chromeVisible = true
    @Published var fontSize = 20.0
    @Published var viewportSize = CGSize(width: 800, height: 620)
    @Published var pageLayoutRaw = "facingPages"
}

private struct MacReflowHarness: View {
    let publication: EPUBPublication
    @ObservedObject var state: MacReflowHarnessState
    let onLoaded: () -> Void
    let onError: (String) -> Void
    let onContentTap: () -> Void
    let onNavigationState: (Int?, Int?, Double) -> Void
    var onChapterBoundary: (Int) -> Void = { _ in }

    var body: some View {
        MacEPUBWebView(
            publication: publication, chapter: state.chapter, initialProgress: state.progress,
            pageLayoutRaw: state.pageLayoutRaw, fontRaw: "georgia", fontSize: state.fontSize,
            background: Color(nsColor: .textBackgroundColor), foreground: Color(nsColor: .labelColor),
            navigationID: state.navigationID, targetFragment: state.fragment, viewportSize: state.viewportSize,
            isChromeVisible: state.chromeVisible, onProgress: { _ in }, onSelection: { _ in },
            onNavigate: { chapter, fragment in
                state.chapter = chapter
                state.fragment = fragment
                state.navigationID = UUID()
            }, onChapterBoundary: onChapterBoundary, onLoaded: onLoaded, onError: onError,
            onContentTap: onContentTap, onNavigationState: onNavigationState
        )
    }
}
