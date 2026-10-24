import XCTest

final class MacReaderUITests: XCTestCase {
    @MainActor
    private func launch(format: String, layout: String = "singlePage", width: Int = 1100) -> XCUIApplication {
        let app = XCUIApplication()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CLOUDREADER_UI_TEST_SESSION"] = UUID().uuidString
        app.launchEnvironment["CLOUDREADER_UI_TEST_FORMAT"] = format
        app.launchEnvironment["CLOUDREADER_UI_TEST_LAYOUT"] = layout
        app.launchEnvironment["CLOUDREADER_UI_TEST_WIDTH"] = String(width)
        app.launchEnvironment["CLOUDREADER_UI_TEST_FIXTURE_ROOT"] = root.path
        // Runtime and UI targets share the isolated app identity. Finish any
        // remaining test-host process before launching a visible reader session.
        if app.state != .notRunning { app.terminate() }
        app.launch()
        return app
    }

    @MainActor
    private func reader(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
    }

    @MainActor
    private func ready(_ app: XCUIApplication) {
        XCTAssertTrue(reader(in: app).waitForExistence(timeout: 20))
        let status = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let measured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", " of ", " of "), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 30), .completed)
    }

    @MainActor
    private func statusText(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func textEquals(_ expected: String) -> NSPredicate {
        NSPredicate(format: "label == %@ OR value == %@", expected, expected)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testEPUBWideSpreadWheelTurnsAndChromeRestores() {
        let app = launch(format: "epub", layout: "facingPages")
        ready(app)
        let status = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(statusText(status).hasPrefix("Pages 1–2 of "), statusText(status))
        capture(app, name: "Mac EPUB visible wide")
        let pageCount = try! XCTUnwrap(statusText(status).components(separatedBy: " of ").last)
        reader(in: app).scroll(byDeltaX: -700, deltaY: 0)
        let turned = XCTNSPredicateExpectation(predicate: textEquals("Pages 3–4 of \(pageCount)"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 10), .completed, "An actual horizontal scroll gesture should turn the spread")
        reader(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["reader.askAI"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["reader.appearance"].exists)
        XCTAssertFalse(status.exists)
        capture(app, name: "Mac EPUB hidden wide")
        app.typeKey("r", modifierFlags: [.command, .shift])
        ready(app)
        XCTAssertTrue(app.buttons["reader.askAI"].exists)
        capture(app, name: "Mac EPUB restored wide")
    }

    @MainActor
    func testEPUBPageButtonsAndChapterJumpsKeepMeasuredNavigation() {
        let app = launch(format: "epub", layout: "facingPages")
        ready(app)
        let status = app.staticTexts["reader.pageStatus"]
        let pageCount = statusText(status).components(separatedBy: " of ").last!
        app.buttons["reader.next"].click()
        let nextSpread = XCTNSPredicateExpectation(predicate: textEquals("Pages 3–4 of \(pageCount)"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [nextSpread], timeout: 10), .completed)
        app.buttons["Next chapter"].click()
        let chapters = app.descendants(matching: .any).matching(identifier: "reader.chapters").firstMatch
        let secondChapter = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Second chapter", "Second chapter"), object: chapters)
        XCTAssertEqual(XCTWaiter.wait(for: [secondChapter], timeout: 10), .completed)
        ready(app)
        XCTAssertTrue(statusText(status).hasPrefix("Pages 1–2 of "), statusText(status))
        capture(app, name: "Mac EPUB next chapter ready")
        chapters.click()
        app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "First chapter")).firstMatch.click()
        let firstChapter = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "First chapter", "First chapter"), object: chapters)
        XCTAssertEqual(XCTWaiter.wait(for: [firstChapter], timeout: 10), .completed)
        ready(app)
        XCTAssertEqual(statusText(status), "Pages 1–2 of \(pageCount)")
        app.buttons["reader.next"].click()
        let resumed = XCTNSPredicateExpectation(predicate: textEquals("Pages 3–4 of \(pageCount)"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed)
        capture(app, name: "Mac EPUB chapter menu return and page turn")
    }

    @MainActor
    func testNarrowEPUBUsesSinglePageAndTXTChromeRestores() {
        let epub = launch(format: "epub", layout: "facingPages", width: 620)
        ready(epub)
        let epubStatus = epub.staticTexts["reader.pageStatus"]
        XCTAssertTrue(statusText(epubStatus).hasPrefix("Page 1 of "))
        let pageCount = try! XCTUnwrap(statusText(epubStatus).components(separatedBy: " of ").last)
        reader(in: epub).scroll(byDeltaX: -500, deltaY: 0)
        let turned = XCTNSPredicateExpectation(predicate: textEquals("Page 2 of \(pageCount)"), object: epubStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 10), .completed)
        capture(epub, name: "Mac EPUB narrow single page")
        epub.terminate()
        let text = launch(format: "txt")
        ready(text)
        reader(in: text).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: text.buttons["reader.askAI"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        capture(text, name: "Mac TXT hidden")
        text.typeKey("r", modifierFlags: [.command, .shift])
        ready(text)
    }

    @MainActor
    func testAllNewFormatsOpenThroughNativeShell() {
        for format in ["fb2", "mobi", "azw3", "cbz", "cbr"] {
            let app = launch(format: format)
            ready(app)
            XCTAssertTrue(app.buttons["reader.appearance"].exists, "Appearance must be reachable for \(format)")
            capture(app, name: "Mac \(format.uppercased()) reader")
            app.terminate()
        }
    }

    @MainActor
    func testComicOddSpreadsAndPDFPageSurviveChrome() {
        let comic = launch(format: "cbz", layout: "facingPages")
        ready(comic)
        let status = comic.staticTexts["reader.pageStatus"]
        XCTAssertEqual(statusText(status), "Pages 1–2 of 5")
        reader(in: comic).scroll(byDeltaX: -700, deltaY: 0)
        let second = XCTNSPredicateExpectation(predicate: textEquals("Pages 3–4 of 5"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed)
        comic.buttons["reader.next"].click()
        let odd = XCTNSPredicateExpectation(predicate: textEquals("Page 5 of 5"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [odd], timeout: 5), .completed)
        XCTAssertFalse(comic.buttons["reader.next"].isEnabled)
        comic.terminate()
        let pdf = launch(format: "pdf")
        ready(pdf)
        pdf.buttons["reader.next"].click()
        let pdfStatus = pdf.staticTexts["reader.pageStatus"]
        let page2 = XCTNSPredicateExpectation(predicate: textEquals("Page 2 of 3"), object: pdfStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [page2], timeout: 5), .completed)
        reader(in: pdf).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).click()
        pdf.typeKey("r", modifierFlags: [.command, .shift])
        ready(pdf)
        XCTAssertEqual(statusText(pdfStatus), "Page 2 of 3")
    }
}
