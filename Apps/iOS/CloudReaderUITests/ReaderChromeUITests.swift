import Network
import XCTest

final class ReaderChromeUITests: XCTestCase {
    @MainActor
    func testBrowseRemoteModelsFromDraftEndpointAndSelectByID() throws {
        let ready = expectation(description: "Loopback provider is ready")
        let requested = expectation(description: "App fetched the draft endpoint's model list")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "CloudReaderTests.modelProvider")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            func receiveHeaders(_ previous: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    guard let data, error == nil else { connection.cancel(); return }
                    let bytes = previous + data
                    let headers = String(decoding: bytes, as: UTF8.self).lowercased()
                    guard headers.contains("\r\n\r\n") else {
                        if complete || bytes.count > 32768 { connection.cancel() } else { receiveHeaders(bytes) }
                        return
                    }
                    XCTAssertTrue(headers.hasPrefix("get /proxy/v1/models "))
                    XCTAssertTrue(headers.contains("authorization: bearer fixture-key"))
                    let body = #"{"data":[{"id":"reader-large","display_name":"Large Reader"},{"id":"reader-small","display_name":"Small Reader"}]}"#
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    requested.fulfill()
                }
            }
            receiveHeaders(Data())
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let provider = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "AI provider")).firstMatch
        for _ in 0..<18 where !provider.isHittable { app.swipeUp() }
        provider.tap()
        app.buttons["Remote API"].firstMatch.tap()
        let endpoint = app.textFields["ai.endpointURL"]
        for _ in 0..<18 where !endpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(endpoint.exists)
        endpoint.tap()
        if let existing = endpoint.value as? String, existing.hasPrefix("http") {
            endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        endpoint.typeText("http://127.0.0.1:\(port)/proxy/v1\n")
        let key = app.secureTextFields["ai.apiKey"]
        key.tap()
        key.typeText("fixture-key\n")
        let browse = app.buttons["ai.browseModels"]
        for _ in 0..<4 where !browse.isHittable { app.swipeUp() }
        browse.tap()
        wait(for: [requested], timeout: 10)
        let row = app.buttons["ai.remoteModel.reader-small"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        if !search.exists { app.buttons["Search"].firstMatch.tap() }
        search.tap()
        search.typeText("small")
        XCTAssertFalse(app.buttons["ai.remoteModel.reader-large"].exists)
        row.tap()
        XCTAssertEqual(app.textFields["ai.modelID"].value as? String, "reader-small")
    }

    @MainActor
    func testChatSendsFromKeyboardHidesKeyboardAndResumesPDFSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reader PDF UI Test Book")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()
        let next = app.buttons["reader.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let page = app.staticTexts["reader.pageStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Page 2 of 3'"), object: page)], timeout: 6), .completed)
        app.buttons["reader.askAI"].tap()
        let field = app.textFields["assistant.question"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Explain this page")
        let hide = app.buttons["Hide keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        XCTAssertEqual(field.value as? String, "Explain this page")
        field.tap()
        field.typeText("\n")
        let context = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "Currently reading:", "Previous page:", "Next page:")).firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 10))
        if context.exists {
            for pageNumber in 1...3 { XCTAssertTrue(context.label.contains("Page \(pageNumber)")) }
        }
        XCTAssertFalse(hide.exists)
        app.buttons["Done"].tap()
        app.buttons["reader.askAI"].tap()
        XCTAssertTrue(app.staticTexts["Explain this page"].waitForExistence(timeout: 5))
        app.buttons["Conversation options"].tap()
        app.buttons["New conversation"].tap()
        XCTAssertFalse(app.staticTexts["Explain this page"].exists)
        XCTAssertTrue(field.exists)
    }

    @MainActor
    func testEPUBChatIncludesTheCurrentChapterAndItsPrecedingBoundary() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reader Swipe Test Book")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()
        let picker = app.buttons["reader.chapters"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["Second chapter"].tap()
        assertChapter("Second chapter", picker: picker)
        try waitForEPUBReady(pageStatus: app.staticTexts["reader.pageStatus"], in: app)
        app.buttons["reader.askAI"].tap()
        let field = app.textFields["assistant.question"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("Explain this chapter\n")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "Chapter 2, passage 0", "Chapter 1, passage 41", "Next page:")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        if answer.exists {
            XCTAssertFalse(answer.label.contains("Chapter 1, passage 20"))
            XCTAssertFalse(answer.label.contains("Chapter 3, passage"))
            XCTAssertFalse(answer.label.contains("Chapter 2, passage 41"))
        }
    }

    @MainActor
    func testReadingSettingShowsTranslationOnWordSelection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["Translate selected English words"].firstMatch
        for _ in 0..<16 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 4), .completed)
        let picker = app.buttons["translation.target"]
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
        picker.tap()
        let french = app.buttons["French"].firstMatch
        for _ in 0..<5 where !french.isHittable { app.swipeUp() }
        XCTAssertTrue(french.waitForExistence(timeout: 5), app.debugDescription)
        french.tap()
        app.buttons["Library"].firstMatch.tap()
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reader PDF UI Test Book")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        fixture.tap()
        let line = app.staticTexts["Reader PDF UI Test Book — Page 1"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.5)).press(forDuration: 0.8)
        let card = app.descendants(matching: .any).matching(identifier: "reader.translation").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reader.translation.language"].label, "French")
        XCTAssertTrue(app.buttons["Dismiss translation"].exists)
    }

    @MainActor
    func testLocalBooksOpenWithoutConnectingCloudStorage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let fixture = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Reader UI Test Book")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), "The library must be available before any provider authorization.")
        fixture.tap()
        let reader = app.descendants(matching: .any).matching(identifier: "reader.content").firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "A local book must open without a CloudReader account or storage connection.")
        XCTAssertTrue(app.buttons["reader.appearance"].waitForExistence(timeout: 3))
        attachScreenshot(app, name: "Local reading without an account")
    }

    @MainActor
    func testCloudProvidersArePresentedAsOptionalStorageConnections() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_TEST_HOST"] = "0"
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()

        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.staticTexts["No account required"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts["settings.cloudStorageExplanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.label.contains("this does not create or sign in to a CloudReader account"))
        attachScreenshot(app, name: "Optional cloud storage, no app account")

        for (provider, title) in [("googleDrive", "Google Drive"), ("dropbox", "Dropbox"), ("pCloud", "pCloud")] {
            let connection = app.buttons["cloudStorage.connect.\(provider)"]
            var swipes = 0
            while (!connection.exists || !connection.isHittable) && swipes < 10 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(connection.exists, "The optional \(title) storage connection should be available.")
            XCTAssertEqual(connection.label, "Connect \(title)", "Storage access must not be described as an app-account login.")
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sign in with ")).firstMatch.exists)
    }

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
        let visibleFrame = reader.frame
        let passageBefore = try renderedPassage(in: reader)
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.32))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(try renderedPassage(in: reader) == passageBefore, "The plain-text passage must stay at the same pixels.")
        attachScreenshot(app, name: "TXT controls visible")

        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)).tap()
        let hiddenToolbar = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: askAI)
        let hiddenAppearance = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: appearance)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenToolbar, hiddenAppearance], timeout: 3), .completed)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Library and Settings tabs must leave the reading surface and accessibility tree.")
        XCTAssertEqual(reader.frame, visibleFrame, "Toggling controls must keep the text viewport fixed.")
        XCTAssertTrue(try renderedPassage(in: reader) == passageBefore, "The plain-text passage must stay at the same pixels.")
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
        reader.swipeLeft()
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

        let reader = app.webViews.firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        let chapterPicker = app.buttons["reader.chapters"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15), "The EPUB should publish its page location.")
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        XCTAssertGreaterThanOrEqual(app.buttons["reader.next"].frame.height, 44)
        XCTAssertEqual(pageStatus.label, "Page 1 of 1")
        XCTAssertEqual(chapterPicker.value as? String, "Cover")
        swipe(in: reader, from: 0.88, to: 0.32, height: 0.77)
        assertChapter("First chapter", picker: chapterPicker)
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        XCTAssertTrue(pageStatus.label.hasPrefix("Page 1 of "))

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

        let count = try XCTUnwrap(Int(pageStatus.label.split(separator: " ").last ?? ""))
        XCTAssertGreaterThan(count, 1)
        for page in 1..<count {
            reader.swipeLeft()
            let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page \(page + 1) of \(count)"), object: pageStatus)
            XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 5), .completed, "One swipe should turn exactly one page.")
        }
        reader.swipeLeft()
        assertChapter("Second chapter", picker: chapterPicker)
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        swipe(in: reader, from: 0.27, to: 0.82, height: 0.32)
        assertChapter("First chapter", picker: chapterPicker)
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        let last = try XCTUnwrap(pageStatus.label.split(separator: " ").last)
        XCTAssertEqual(pageStatus.label, "Page \(last) of \(last)")
    }

    @MainActor
    func testPagedEPUBKeepsPassageStillDuringDraggingAndControlChanges() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reader Swipe Test Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()

        let page = app.webViews.firstMatch
        let status = app.staticTexts["reader.pageStatus"]
        let appearance = app.buttons["reader.appearance"]
        try waitForEPUBReady(pageStatus: status, in: app)
        app.buttons["reader.next"].tap()
        assertChapter("First chapter", picker: app.buttons["reader.chapters"])
        page.swipeLeft()
        let secondPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "Page 2 of "), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [secondPage], timeout: 5), .completed)
        let originalStatus = status.label
        let originalFrame = page.frame
        let originalPassage = try renderedPassage(in: page)

        let center = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
        let lower = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        center.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertEqual(status.label, originalStatus)
        XCTAssertTrue(try renderedPassage(in: page) == originalPassage, "The EPUB passage must stay at the same pixels.")

        center.tap()
        XCTAssertTrue(appearance.waitForNonExistence(timeout: 5))
        XCTAssertEqual(page.frame, originalFrame)
        XCTAssertTrue(try renderedPassage(in: page) == originalPassage, "The EPUB passage must stay at the same pixels.")
        center.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertEqual(page.frame, originalFrame)
        XCTAssertTrue(try renderedPassage(in: page) == originalPassage, "The EPUB passage must stay at the same pixels.")
        appearance.tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(status.label, originalStatus)
        XCTAssertTrue(try renderedPassage(in: page) == originalPassage, "The EPUB passage must stay at the same pixels.")
    }

    @MainActor
    private func renderedPassage(in page: XCUIElement) throws -> Data {
        let image = try XCTUnwrap(page.screenshot().image.cgImage)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Compare only the prose between the two toolbars.
        let region = CGRect(x: width * 0.12, y: height * 0.35, width: width * 0.76, height: height * 0.25).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        return try XCTUnwrap(UIImage(cgImage: crop).pngData())
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

        let reader = app.webViews.firstMatch
        let pageStatus = app.staticTexts["reader.pageStatus"]
        let chapterPicker = app.buttons["reader.chapters"]
        XCTAssertTrue(pageStatus.waitForExistence(timeout: 15))
        XCTAssertTrue(chapterPicker.waitForExistence(timeout: 10))
        try waitForEPUBReady(pageStatus: pageStatus, in: app)
        try requireWideReader(reader)
        reader.swipeLeft()
        assertChapter("First chapter", picker: chapterPicker)
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
    func testScrollingEPUBSwipesOffCoverAndBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLOUDREADER_UI_TEST_MODE"] = "1"
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reader Swipe Test Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        let appearance = app.buttons["reader.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        app.buttons["Scrolling"].tap()
        app.buttons["Done"].tap()

        let reader = app.webViews.firstMatch
        let chapters = app.buttons["reader.chapters"]
        assertChapter("Cover", picker: chapters)
        swipe(in: reader, from: 0.82, to: 0.28, height: 0.72)
        assertChapter("First chapter", picker: chapters)
        reader.swipeDown()
        assertChapter("Cover", picker: chapters)
        reader.swipeUp()
        assertChapter("First chapter", picker: chapters)

        let status = app.staticTexts["reader.pageStatus"]
        let firstScreen = status.label
        swipe(in: reader, from: 0.78, to: 0.22, height: 0.40)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", firstScreen), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        XCTAssertEqual(chapters.value as? String, "First chapter")
    }

    @MainActor
    private func swipe(in reader: XCUIElement, from: CGFloat, to: CGFloat, height: CGFloat) {
        // Use the visible page's window coordinates. Resolving two relative coordinates
        // during a drag can target different frames while system bars are animating.
        let frame = reader.frame
        let origin = XCUIApplication().coordinate(withNormalizedOffset: .zero)
        let y = frame.minY + frame.height * height
        let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * from, dy: y))
        let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * to, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func assertChapter(_ title: String, picker: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Expected chapter \(title).", file: file, line: line)
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
