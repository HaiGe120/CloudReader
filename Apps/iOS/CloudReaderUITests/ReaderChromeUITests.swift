import XCTest

final class ReaderChromeUITests: XCTestCase {
    @MainActor
    func testContentTapHidesAndRestoresReadingChrome() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The isolated fixture should be in the library.")
        fixture.tap()

        let askAI = app.buttons["reader.askAI"]
        let appearance = app.buttons["reader.appearance"]
        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        XCTAssertTrue(askAI.waitForExistence(timeout: 10), "The reader toolbar should be visible when the book opens.")
        XCTAssertTrue(appearance.waitForExistence(timeout: 3), "The reading appearance control should be visible with the chrome.")
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The fixture should open in the actual reader.")
        let visibleHeight = reader.frame.height
        attachScreenshot(app, name: "TXT controls visible")

        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        let hiddenToolbar = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: askAI)
        let hiddenAppearance = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: appearance)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenToolbar, hiddenAppearance], timeout: 3), .completed)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Library and Settings tabs must leave the reading surface and accessibility tree.")
        XCTAssertGreaterThan(reader.frame.height, visibleHeight, "Hidden controls must release their layout space.")
        attachScreenshot(app, name: "TXT controls hidden")

        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        XCTAssertTrue(askAI.waitForExistence(timeout: 3), "A second content tap should restore the reading controls.")
        XCTAssertTrue(appearance.waitForExistence(timeout: 3), "Restoring the chrome should restore its appearance control too.")
    }

    @MainActor
    func testPDFChromeRestoresWithoutChangingTheCurrentPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader PDF UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The isolated PDF fixture should be in the library.")
        fixture.tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        XCTAssertEqual(pageStatus.label, "Page 1 of 3")
        app.buttons["reader.next"].tap()
        let secondPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 2 of 3"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [secondPage], timeout: 5), .completed)

        let askAI = app.buttons["reader.askAI"]
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: askAI)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(pageStatus.label, "Page 2 of 3", "Restoring controls must keep the PDF at its current page.")
    }

    @MainActor
    func testEPUBSwipesTurnPagesAndCrossChapterBoundary() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader Swipe Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The isolated EPUB fixture should be in the library.")
        fixture.tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        let chapterPicker = app.buttons["reader.chapters"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15), "The EPUB should publish its page location.")
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        XCTAssertEqual(chapterPicker.value as? String, "First chapter")

        attachScreenshot(app, name: "EPUB controls visible")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        let chromeHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: chapterPicker)
        XCTAssertEqual(XCTWaiter.wait(for: [chromeHidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["reader.askAI"].exists)
        XCTAssertFalse(app.buttons["reader.appearance"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attachScreenshot(app, name: "EPUB controls hidden")
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        XCTAssertTrue(chapterPicker.waitForExistence(timeout: 5))
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        attachScreenshot(app, name: "EPUB controls restored")

        let initialStatus = pageStatus.label
        reader.swipeLeft()
        let firstTurn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initialStatus), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [firstTurn], timeout: 5), .completed, "A physical swipe should turn to the next EPUB page.")

        var attempts = 0
        while (chapterPicker.value as? String) != "Second chapter" && attempts < 18 {
            let previousStatus = pageStatus.label
            reader.swipeLeft()
            let turn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previousStatus), object: pageStatus)
            _ = XCTWaiter.wait(for: [turn], timeout: 3)
            attempts += 1
        }
        XCTAssertEqual(chapterPicker.value as? String, "Second chapter", "Swiping beyond a chapter's last page should open the next chapter.")
    }

    @MainActor
    func testFB2OpensInTheSharedReflowReader() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader FB2 UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The isolated FB2 fixture should be in the library.")
        fixture.tap()

        let chapterPicker = app.buttons["reader.chapters"]
        let pageStatus = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(chapterPicker.waitForExistence(timeout: 15), "FB2 should use the shared reflowable reader controls.")
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15), "The FB2 reader should publish its chapter/page state.")
        XCTAssertEqual(chapterPicker.value as? String, "Reader FB2 UI Test Book")
    }

    @MainActor
    func testCBZSinglePageSwipeTurnsComicPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader Comic UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The isolated CBZ fixture should be in the library.")
        fixture.tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        XCTAssertEqual(pageStatus.label, "Page 1 of 5")
        reader.swipeLeft()
        let nextPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 2 of 5"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [nextPage], timeout: 5), .completed, "A horizontal swipe should turn one comic page.")
    }

    @MainActor
    func testCBZOddFinalPageRemainsAloneInWideSpreadMode() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader Comic UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()

        let appearance = app.buttons["reader.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let spreads = app.buttons["Two pages"]
        XCTAssertTrue(spreads.waitForExistence(timeout: 5))
        spreads.tap()
        app.buttons["Done"].tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        try requireWideReader(reader)
        let firstSpread = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pages 1–2 of 5"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [firstSpread], timeout: 5), .completed, "A wide CBZ should begin with its first two-page spread.")
        reader.swipeLeft()
        let nextSpread = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pages 3–4 of 5"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [nextSpread], timeout: 5), .completed)
        reader.swipeLeft()
        let finalPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 5 of 5"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [finalPage], timeout: 5), .completed, "The odd final image should occupy a one-page spread.")
    }

    @MainActor
    func testWideTXTDoesNotInventASecondPageForASinglePageBook() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()

        let appearance = app.buttons["reader.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let spreads = app.buttons["Two pages"]
        XCTAssertTrue(spreads.waitForExistence(timeout: 5))
        spreads.tap()
        app.buttons["Done"].tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        try requireWideReader(reader)
        let onlyPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 1 of 1"), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [onlyPage], timeout: 5), .completed, "A one-page TXT book should occupy one page without an empty companion page.")
        XCTAssertFalse(app.buttons["reader.next"].isEnabled, "A single-page TXT book should not expose a phantom next page.")
    }

    @MainActor
    func testWideEPUBUsesAndSwipesTwoPageSpreads() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader Swipe Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()

        let appearance = app.buttons["reader.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let spreads = app.buttons["Two pages"]
        XCTAssertTrue(spreads.waitForExistence(timeout: 5))
        spreads.tap()
        app.buttons["Done"].tap()

        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        let chapterPicker = app.buttons["reader.chapters"]
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        XCTAssertTrue(chapterPicker.waitForExistence(timeout: 10))
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        try requireWideReader(reader)
        let firstSpread = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Pages 1–2 of "), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [firstSpread], timeout: 5), .completed, "A wide reader should show an actual two-page spread; got: \(pageStatus.label)")
        XCTAssertEqual(chapterPicker.value as? String, "First chapter")
        let initialStatus = pageStatus.label
        reader.swipeLeft()
        let nextSpread = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initialStatus), object: pageStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [nextSpread], timeout: 5), .completed, "A physical swipe should turn the entire EPUB spread.")
        if (chapterPicker.value as? String) == "First chapter" {
            XCTAssertTrue(pageStatus.label.hasPrefix("Pages 3–4 of "), "The swipe should advance one complete two-page spread.")
        }

        var attempts = 1
        while (chapterPicker.value as? String) != "Second chapter" && attempts < 18 {
            let previousStatus = pageStatus.label
            reader.swipeLeft()
            let turn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previousStatus), object: pageStatus)
            XCTAssertEqual(XCTWaiter.wait(for: [turn], timeout: 5), .completed, "Every wide-layout swipe should advance the visible spread or chapter.")
            attempts += 1
        }
        XCTAssertEqual(chapterPicker.value as? String, "Second chapter", "Swiping the final spread of a chapter should enter the next chapter in wide mode.")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForEPUBReady(pageStatus: XCUIElement, in app: XCUIApplication) throws {
        let paginated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", " of "),
            object: pageStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [paginated], timeout: 20), .completed, "The EPUB must finish pagination before a swipe is tested.")

        let loading = app.descendants(matching: .any).matching(identifier: "reader.loading").firstMatch
        if loading.exists {
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed, "The opening overlay must release the reading surface before gestures.")
        }
    }

    @MainActor
    private func requireWideReader(_ reader: XCUIElement) throws {
        let width = reader.frame.width
        XCTAssertGreaterThan(width, 0, "The reader must have a measurable viewport before the spread gate is evaluated.")
        guard width > 0 else { return }
        if width < 700 {
            throw XCTSkip("Effective reader width is \(Int(width)) pt, below the 700 pt two-page breakpoint.")
        }
    }
}
