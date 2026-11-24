import CloudReaderCore
import Translation
#if os(macOS)
import AppKit
#endif
import XCTest
@testable import CloudReader

final class ReaderContractTests: XCTestCase {
    func testPageWindowKeepsChapterOrderBoundsAndVisibleSpread() throws {
        let pages = ["before", "current", "also current", "after", "unrelated"]
        let context = try XCTUnwrap(ReaderPageContext.pages(count: pages.count, first: 1, visibleCount: 2) { pages[$0] })
        XCTAssertEqual(context.current, "current\n\nalso current")
        XCTAssertEqual(context.previous, "before")
        XCTAssertEqual(context.next, "after")
        XCTAssertFalse(try XCTUnwrap(context.excerpt(limit: 6000)).contains("unrelated"))
        XCTAssertNil(ReaderPageContext.pages(count: 1, first: 0, visibleCount: 1) { _ in "Only" }?.previous)
        XCTAssertNil(ReaderPageContext.pages(count: 1, first: 0, visibleCount: 1) { _ in "Only" }?.next)
        XCTAssertNil(ReaderPageContext.pages(count: 0, first: 0, visibleCount: 1) { _ in "Unexpected" })
    }

    @MainActor
    func testTranslationAcceptsOnlyOneEnglishWord() {
        XCTAssertEqual(ReaderWordTranslation.englishWord(" “well-being” "), "well-being")
        XCTAssertEqual(ReaderWordTranslation.englishWord("reader’s"), "reader’s")
        for text in ["two words", "中文", "page123", "", String(repeating: "a", count: 150)] {
            XCTAssertNil(ReaderWordTranslation.englishWord(text))
        }
    }

    func testTranslationPreferencePreservesExistingReadersAndExplicitChoices() throws {
        let suite = "CloudReader-Translation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ReaderTranslationTarget.initializePreference(in: defaults)
        XCTAssertEqual(defaults.string(forKey: ReaderTranslationTarget.key), ReaderTranslationTarget.automatic)
        XCTAssertNil(ReaderTranslationTarget.language(for: ReaderTranslationTarget.automatic))

        defaults.removeObject(forKey: ReaderTranslationTarget.key)
        defaults.set(true, forKey: ReaderTranslationTarget.enabledKey)
        ReaderTranslationTarget.initializePreference(in: defaults)
        XCTAssertEqual(defaults.string(forKey: ReaderTranslationTarget.key), "zh-Hans")
        defaults.set("fr-CA", forKey: ReaderTranslationTarget.key)
        ReaderTranslationTarget.initializePreference(in: defaults)
        let saved = try XCTUnwrap(defaults.string(forKey: ReaderTranslationTarget.key))
        let language = try XCTUnwrap(ReaderTranslationTarget.language(for: saved))
        XCTAssertEqual(ReaderTranslationTarget.identifier(for: language), "fr-CA")
        XCTAssertEqual(ReaderTranslationTarget.identifier(for: Locale.Language(identifier: "zh-CN")), "zh-Hans")
        XCTAssertEqual(ReaderTranslationTarget.identifier(for: Locale.Language(identifier: "zh-TW")), "zh-Hant")
    }

    #if !targetEnvironment(simulator)
    func testAvailableFrenchTargetTranslatesWithInstalledSystemModel() async throws {
        let identifiers = await ReaderTranslationTarget.supportedIdentifiers()
        XCTAssertFalse(identifiers.contains { Locale.Language(identifier: $0).languageCode?.identifier == "en" })
        let french = Locale.Language(identifier: "fr")
        let status = await LanguageAvailability().status(from: ReaderTranslationTarget.english, to: french)
        try XCTSkipIf(status == .unsupported, "French translation is unavailable on this device.")
        let identifier = try XCTUnwrap(identifiers.first { Locale.Language(identifier: $0).isEquivalent(to: french) })
        let target = try XCTUnwrap(ReaderTranslationTarget.language(for: identifier))
        guard #available(iOS 26, macOS 26, *) else { throw XCTSkip("A standalone translation session requires OS 26.") }
        try XCTSkipUnless(status == .installed, "French is available for selection. Its model is not installed.")
        let response = try await TranslationSession(installedSource: ReaderTranslationTarget.english, target: target).translate("curiosity")
        XCTAssertTrue(response.targetLanguage.isEquivalent(to: french))
        XCTAssertFalse(response.targetText.isEmpty)
        XCTAssertNotEqual(response.targetText.lowercased(), "curiosity")
    }
    #endif

    func testModelListUsesProviderBaseAndDraftCredentialsBeforeSaving() async throws {
        for kind in AIEndpointKind.allCases {
            var profile = AIProviderConfiguration()
            profile.endpointKind = kind
            let endpoint = try XCTUnwrap(AIService.endpoint(for: profile))
            XCTAssertEqual(endpoint.absoluteString, kind.defaultEndpoint)
            let entries = try await AIModelCatalog.models(endpoint: endpoint, kind: kind, key: "fixture") { request in
                XCTAssertEqual(request.url?.path, "/v1/models")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                if kind == .anthropicMessages {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                }
                return try self.catalogResponse(#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"id":""}]}"#, to: request)
            }
            XCTAssertEqual(entries.map(\.id), ["a", "b"])
        }
        var profile = AIProviderConfiguration()
        profile.endpointURL = "https://gateway.example/api/v1/?api-version=1"
        let endpoint = try XCTUnwrap(AIService.endpoint(for: profile))
        XCTAssertEqual(endpoint.path, "/api/v1/responses")
        let savedOrigin = URL(string: "https://gateway.example")
        XCTAssertEqual(try AIProfileStore.requestKey(for: profile, entered: "") { ("saved", savedOrigin) }, "saved")
        profile.endpointURL = "https://gateway.example:9443/v1"
        XCTAssertThrowsError(try AIProfileStore.requestKey(for: profile, entered: "") { ("saved", savedOrigin) })
        XCTAssertEqual(try AIProfileStore.requestKey(for: profile, entered: " new ") { XCTFail("Typed key takes priority"); return nil }, "new")
        for invalid in ["http://example.com/v1", "https://someone@example.com/v1", "not-a-url"] {
            profile.endpointURL = invalid
            XCTAssertNil(AIService.endpoint(for: profile))
        }
        for value in ["https://gateway.example", "http://127.0.0.1:4000", "http://[::1]:4000"] {
            profile.endpointURL = value
            XCTAssertEqual(AIService.endpoint(for: profile)?.path, "/v1/responses")
        }
    }

    func testModelListFollowsAnthropicCursorsAndPreservesCustomRoute() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example/prefix/v1/messages/?api-version=1"))
        var queries: [[URLQueryItem]] = []
        let models = try await AIModelCatalog.models(endpoint: endpoint, kind: .anthropicMessages, key: nil) { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/prefix/v1/models")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            queries.append(query)
            let body = queries.count == 1 ? #"{"data":[{"id":"custom:b","display_name":"Beta"}],"has_more":true,"last_id":"b/1"}"#
                                          : #"{"data":[{"id":"custom:a","display_name":"Alpha"}],"has_more":false}"#
            return try self.catalogResponse(body, to: request)
        }
        XCTAssertEqual(models.map(\.id), ["custom:a", "custom:b"])
        XCTAssertEqual(models.first?.title, "Alpha")
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.allSatisfy { $0.contains(URLQueryItem(name: "api-version", value: "1")) })
        XCTAssertTrue(queries[1].contains(URLQueryItem(name: "after_id", value: "b/1")))
        var pages = 0
        do {
            _ = try await AIModelCatalog.models(endpoint: endpoint, kind: .anthropicMessages, key: nil) { request in
                pages += 1
                return try self.catalogResponse(#"{"data":[],"has_more":true,"last_id":"same"}"#, to: request)
            }
            XCTFail("A repeated cursor must stop pagination")
        } catch AIServiceError.unreadableResponse { XCTAssertEqual(pages, 2) }
    }

    func testModelListReportsEmptyUnauthorizedAndMalformedResponses() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/v1/chat/completions"))
        let empty = try await AIModelCatalog.models(endpoint: endpoint, kind: .openAIChatCompletions, key: nil) { request in
            try self.catalogResponse(#"{"data":[]}"#, to: request)
        }
        XCTAssertTrue(empty.isEmpty)
        for (body, code) in [("key-should-never-appear-in-errors", 401), ("{}", 200)] {
            do {
                _ = try await AIModelCatalog.models(endpoint: endpoint, kind: .openAIChatCompletions, key: nil) { request in
                    try self.catalogResponse(body, to: request, status: code)
                }
                XCTFail("Expected an error for \(code)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("key-should-never-appear-in-errors"))
                XCTAssertTrue(error.localizedDescription.contains(code == 401 ? "401" : "could not read"))
            }
        }
    }

    private func catalogResponse(_ body: String, to request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(body.utf8), response)
    }

    func testProviderNativeSearchIsOptInAndCitationsSurvive() throws {
        var profile = try JSONDecoder().decode(AIProviderConfiguration.self, from: Data("{}".utf8))
        func payload() throws -> [String: Any] {
            let data = try AIService.makePayload(profile: profile, messages: [.user("Why?")], instructions: "Answer.")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for kind in AIEndpointKind.allCases {
            profile.endpointKind = kind
            profile.webSearchEnabled = false
            XCTAssertNil(try payload()["tools"])
            XCTAssertNil(try payload()["web_search_options"])
            profile.webSearchEnabled = true
            switch kind {
            case .openAIResponses: XCTAssertEqual((try payload()["tools"] as? [[String: String]])?.first?["type"], "web_search")
            case .openAIChatCompletions: XCTAssertNotNil(try payload()["web_search_options"])
            case .anthropicMessages: XCTAssertEqual((try payload()["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search_20250305")
            }
        }
        XCTAssertTrue(try JSONDecoder().decode(AIProviderConfiguration.self, from: JSONEncoder().encode(profile)).webSearchEnabled)
        let data = Data(#"{"output":[{"content":[{"type":"output_text","text":"Fact. More.","annotations":[{"type":"url_citation","end_index":5,"url":"https://example.com/source"}]}]}]}"#.utf8)
        XCTAssertEqual(AIService.decodeAnswer(from: data, kind: .openAIResponses), "Fact. [example.com](https://example.com/source) More.")
        let error = Data(#"{"content":[{"type":"web_search_tool_result","content":{"error_code":"unavailable"}}]}"#.utf8)
        XCTAssertEqual(AIService.searchError(from: error), "unavailable")
    }

    func testLongChatRetainsCompleteRecentTurnsAndPausedSearchKeepsProviderBlocks() throws {
        let messages: [AIConversationMessage] = [.user("Earlier"), .assistant("Earlier answer"), .user("New"), .assistant("Reply"), .user("Now")]
        XCTAssertEqual(AIService.recentMessages(messages, budget: 12).map(\.text), ["New", "Reply", "Now"])
        XCTAssertEqual(AIService.recentMessages(messages, budget: 10).map(\.text), ["Now"])
        var request = URLRequest(url: URL(string: "https://example.test")!)
        request.httpBody = Data(#"{"messages":[{"role":"user","content":"Question"}]}"#.utf8)
        let response = Data(#"{"stop_reason":"pause_turn","content":[{"type":"server_tool_use","id":"tool-1"}]}"#.utf8)
        let data = try XCTUnwrap(AIService.continuedSearchBody(request: request, response: response))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let continued = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(continued.count, 2)
        XCTAssertEqual((continued.last?["content"] as? [[String: String]])?.first?["id"], "tool-1")
    }

    #if os(macOS)
    @MainActor
    func testScrollingTextUsesVisibleLinesInsideALongParagraph() throws {
        let viewport = MacTextViewport()
        let text = (1...100).map { "Marker \($0)" }.joined(separator: "\n")
        viewport.frames = [0: CGRect(x: 0, y: -1000, width: 300, height: 2000)]
        let window = try XCTUnwrap(viewport.context(paragraphs: [text], width: 300, height: 100, font: .systemFont(ofSize: 16)))
        XCTAssertTrue(window.current?.contains("Marker 52") == true)
        XCTAssertFalse(window.current?.contains("Marker 1\n") == true)
        XCTAssertTrue(window.previous?.contains("Marker 48") == true)
        XCTAssertTrue(window.next?.contains("Marker 58") == true)
    }
    #endif

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
