import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CloudReaderCore

struct MacEPUBBookReader: View {
    let bookID: UUID
    let url: URL
    let progress: Double
    let pageLayoutRaw: String
    let fontRaw: String
    let fontSize: Double
    let background: Color
    let foreground: Color
    let onProgressChanged: (Double) -> Void
    let onSelectionChanged: (String) -> Void
    var sourceFormat: BookFormat = .epub
    var isChromeVisible = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onContentTap: () -> Void = {}
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }

    @State private var publication: EPUBPublication?
    @State private var loadedSourceURL: URL?
    @State private var chapter = 0
    @State private var chapterProgress = 0.0
    @State private var loadError: String?
    @State private var isLoadingChapter = true
    @State private var showsChapterLoadingIndicator = false
    @State private var reloadID = UUID()
    @State private var navigationID = UUID()
    @State private var targetFragment: String?
    @State private var viewportSize: CGSize = .zero
    @State private var currentPage: Int?
    @State private var currentPageCount: Int?
    @State private var lastConsumedRequestID: UUID?
    @State private var pendingPageTurn: Int?
    @State private var chapterGeneration = UUID()

    var body: some View {
        Group {
            if let publication, loadedSourceURL == url, !publication.chapters.isEmpty {
                GeometryReader { geometry in
                    let renderedChapter = chapter
                    let renderedGeneration = chapterGeneration
                    ZStack {
                        MacEPUBWebView(
                            publication: publication,
                            chapter: renderedChapter,
                            initialProgress: chapterProgress,
                            pageLayoutRaw: pageLayoutRaw,
                            fontRaw: fontRaw,
                            fontSize: fontSize,
                            background: background,
                            foreground: foreground,
                            navigationID: navigationID,
                            targetFragment: targetFragment,
                            viewportSize: geometry.size,
                            isChromeVisible: isChromeVisible,
                            onProgress: { fraction in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                chapterProgress = fraction
                                let value = EPUBPublication.progress(chapter: renderedChapter, fraction: fraction, chapterCount: publication.chapters.count)
                                onProgressChanged(value)
                            },
                            onSelection: { text in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                onSelectionChanged(text)
                            },
                            onNavigate: { index, fragment in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                navigate(to: index, in: publication, fragment: fragment)
                            },
                            onChapterBoundary: { direction in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                navigateAcrossBoundary(direction, in: publication)
                            },
                            onLoaded: {
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                isLoadingChapter = false
                                targetFragment = nil
                            },
                            onError: { error in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                loadError = error
                                isLoadingChapter = false
                            },
                            onContentTap: {
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                onContentTap()
                            },
                            onNavigationState: { page, pages, fraction in
                                guard chapter == renderedChapter, chapterGeneration == renderedGeneration else { return }
                                currentPage = page
                                currentPageCount = pages
                                if page != nil { pendingPageTurn = nil }
                                let value = EPUBPublication.progress(chapter: renderedChapter, fraction: fraction, chapterCount: publication.chapters.count)
                                onProgressChanged(value)
                                publishState(publication, progress: value, page: page, pages: pages)
                            }
                        )
                        .id(EPUBMacSource(url: url, bookID: bookID, reloadID: reloadID))
                        if isLoadingChapter && showsChapterLoadingIndicator {
                            ProgressView("Opening chapter…")
                                .padding(14)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .onAppear { viewportSize = geometry.size }
                    .onChange(of: geometry.size) { viewportSize = geometry.size }
                }
            } else if loadError == nil {
                ProgressView("Preparing book…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(background)
        .overlay {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't open \(sourceFormat.displayName)", systemImage: "book.closed")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        self.loadError = nil
                        isLoadingChapter = true
                        publication = nil
                        loadedSourceURL = nil
                        reloadID = UUID()
                    }.buttonStyle(.bordered)
                }.background(background)
            }
        }
        .task(id: EPUBMacLoadRequest(url: url, bookID: bookID, reloadID: reloadID)) {
            if loadedSourceURL != url || publication == nil {
                publication = nil
                loadError = nil
                loadedSourceURL = url
                isLoadingChapter = true
            }
            guard publication == nil else { return }
            do {
                let loaded: EPUBPublication
                switch sourceFormat {
                case .fb2: loaded = try await FB2Loader.shared.open(url: url, bookID: bookID)
                case .mobi, .azw3: loaded = try await KindleLoader.shared.open(url: url, bookID: bookID)
                default: loaded = try await EPUBLoader.shared.open(url: url, bookID: bookID)
                }
                try Task.checkCancellation()
                guard !loaded.chapters.isEmpty else { throw EPUBError.invalidBook }
                let location = EPUBPublication.location(progress: progress, chapterCount: loaded.chapters.count)
                chapter = location.chapter
                chapterProgress = location.fraction
                chapterGeneration = UUID()
                publication = loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
        .task(id: isLoadingChapter) {
            showsChapterLoadingIndicator = false
            guard isLoadingChapter else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, isLoadingChapter else { return }
            showsChapterLoadingIndicator = true
        }
        .onAppear { consume(navigationRequest) }
        .onChange(of: navigationRequest) { consume(navigationRequest) }
        .onChange(of: publication != nil) { if publication != nil { consume(navigationRequest) } }
        .onChange(of: viewportSize) {
            if let publication { publishState(publication, progress: progress, page: currentPage, pages: currentPageCount) }
        }
    }

    private func navigate(to index: Int, in publication: EPUBPublication, fragment: String? = nil) {
        guard publication.chapters.indices.contains(index) else { return }
        let changesChapter = index != chapter
        guard changesChapter || fragment != nil else { return }
        chapter = index
        if changesChapter { chapterGeneration = UUID() }
        targetFragment = fragment
        if changesChapter {
            chapterProgress = 0
            currentPage = nil; currentPageCount = nil; pendingPageTurn = nil
            onProgressChanged(EPUBPublication.progress(chapter: index, fraction: 0, chapterCount: publication.chapters.count))
        }
        navigationID = UUID()
        isLoadingChapter = changesChapter
        onSelectionChanged("")
    }

    private func consume(_ request: ReaderNavigationRequest?) {
        guard let request, request.id != lastConsumedRequestID, let publication else { return }
        lastConsumedRequestID = request.id
        switch request.command {
        case .previous: turn(-1, in: publication)
        case .next: turn(1, in: publication)
        case .previousChapter: navigate(to: chapter - 1, in: publication)
        case .nextChapter: navigate(to: chapter + 1, in: publication)
        case .chapter(let index): navigate(to: index, in: publication)
        case .seek(let value): targetFragment = nil; let location = EPUBPublication.location(progress: value, chapterCount: publication.chapters.count); navigate(to: location.chapter, in: publication); chapterProgress = location.fraction; navigationID = UUID()
        }
    }

    private func turn(_ direction: Int, in publication: EPUBPublication) {
        targetFragment = nil
        let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
        guard let count = currentPageCount else {
            if direction < 0 && chapterProgress > 0.002 { chapterProgress = max(0, chapterProgress - 0.08); navigationID = UUID() }
            else if direction > 0 && chapterProgress < 0.998 { chapterProgress = min(1, chapterProgress + 0.08); navigationID = UUID() }
            else { navigateAcrossBoundary(direction, in: publication) }
            return
        }
        let scrolling = layout == .scroll
        let columns = scrolling ? 1 : ReaderLayoutMetrics.resolve(viewport: viewportSize, pageLayout: layout, font: ReaderFont(rawValue: fontRaw) ?? .systemSerif, fontSize: CGFloat(fontSize)).effectiveColumnCount
        let firstPage = scrolling ? 0 : 1
        let page = pendingPageTurn ?? currentPage ?? firstPage
        let destination = page + direction * columns
        if destination >= firstPage && destination < count + (scrolling ? 0 : 1) {
            pendingPageTurn = destination
            if scrolling {
                chapterProgress = Double(max(destination, 0)) / Double(max(count - 1, 1))
            } else {
                let spread = max(destination - 1, 0) / columns
                let spreadCount = max((count + columns - 1) / columns, 1)
                chapterProgress = Double(spread) / Double(max(spreadCount - 1, 1))
            }
            navigationID = UUID()
        } else { navigateAcrossBoundary(direction, in: publication) }
    }

    private func navigateAcrossBoundary(_ direction: Int, in publication: EPUBPublication) {
        let destination = chapter + direction
        guard publication.chapters.indices.contains(destination) else { return }
        chapter = destination
        chapterGeneration = UUID()
        targetFragment = nil
        let fraction = direction < 0 ? 1 - 1e-8 : 0
        chapterProgress = fraction
        currentPage = nil
        currentPageCount = nil
        pendingPageTurn = nil
        navigationID = UUID()
        isLoadingChapter = true
        onSelectionChanged("")
        onProgressChanged(EPUBPublication.progress(chapter: destination, fraction: fraction, chapterCount: publication.chapters.count))
    }

    private func publishState(_ publication: EPUBPublication, progress: Double, page: Int?, pages: Int?) {
        let columns = ReaderLayoutMetrics.resolve(viewport: viewportSize, pageLayout: ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll, font: ReaderFont(rawValue: fontRaw) ?? .systemSerif, fontSize: CGFloat(fontSize)).effectiveColumnCount
        let range = page.map { $0...max($0, min($0 + columns - 1, pages ?? $0)) }
        let paged = (ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll) != .scroll
        onNavigationStateChanged(ReaderNavigationState(progress: progress, pageRange: paged ? range : nil, pageCount: paged ? pages : nil, chapterIndex: chapter, chapterCount: publication.chapters.count, chapterTitles: publication.chapters.map(\.title), canNavigatePrevious: chapter > 0 || progress > 0, canNavigateNext: chapter < publication.chapters.count - 1 || progress < 1))
    }
}

private struct EPUBMacSource: Hashable {
    let url: URL
    let bookID: UUID
    let reloadID: UUID
}

private struct EPUBMacLoadRequest: Hashable {
    let url: URL
    let bookID: UUID
    let reloadID: UUID
}

struct MacEPUBWebView: NSViewRepresentable {
    let publication: EPUBPublication
    let chapter: Int
    let initialProgress: Double
    let pageLayoutRaw: String
    let fontRaw: String
    let fontSize: Double
    let background: Color
    let foreground: Color
    let navigationID: UUID
    let targetFragment: String?
    let viewportSize: CGSize
    let isChromeVisible: Bool
    let onProgress: (Double) -> Void
    let onSelection: (String) -> Void
    let onNavigate: (Int, String?) -> Void
    let onChapterBoundary: (Int) -> Void
    let onLoaded: () -> Void
    let onError: (String) -> Void
    let onContentTap: () -> Void
    let onNavigationState: (Int?, Int?, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MacEPUBResourceHandler(root: publication.rootURL, mediaTypes: publication.mediaTypes),
            forURLScheme: "cloudreader-epub"
        )
        let content = WKUserContentController()
        content.add(context.coordinator, contentWorld: .defaultClient, name: "reader")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        content.addUserScript(WKUserScript(source: Self.viewportScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        content.addUserScript(WKUserScript(
            source: Self.readerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        configuration.userContentController = content

        let view = MacReaderWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.pageLayoutRaw = pageLayoutRaw
        view.onPageTurn = { [weak coordinator = context.coordinator] direction in coordinator?.turnPage(direction) }
        context.coordinator.view = view
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let readerView = view as? MacReaderWKWebView { readerView.pageLayoutRaw = pageLayoutRaw }
        view.underPageBackgroundColor = NSColor(background)
        if context.coordinator.nonSpineDocumentPath != nil,
           context.coordinator.lastNavigationID != navigationID {
            context.coordinator.nonSpineDocumentPath = nil
        }
        let path = context.coordinator.nonSpineDocumentPath ?? publication.chapters[chapter].path
        if context.coordinator.loadedPath != path {
            context.coordinator.loadDocument(path: path, fraction: initialProgress, fragment: targetFragment)
        } else {
            let needsNavigation = context.coordinator.lastNavigationID != navigationID
            if needsNavigation {
                // A jump can arrive before didFinish or while initial layout is
                // settling. Keep its destination until this document is ready.
                context.coordinator.lastNavigationID = navigationID
                context.coordinator.restoreFraction = initialProgress
                context.coordinator.restoreFragment = targetFragment
            }
            if context.coordinator.isReady {
                context.coordinator.applyAppearance(restoring: needsNavigation ? initialProgress : nil, fragment: needsNavigation ? targetFragment : nil)
            }
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPresentation()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MacEPUBWebView
        weak var view: WKWebView?
        var loadedPath: String?
        var isReady = false
        var restoreFraction = 0.0
        var restoreFragment: String?
        var lastNavigationID: UUID?
        var nonSpineDocumentPath: String?
        private var activeNavigation: WKNavigation?
        private var documentID = UUID()
        private var appearanceKey = ""
        private var configurationID = UUID()
        private var pendingLoadNotification = false
        private var timeoutTask: Task<Void, Never>?

        init(parent: MacEPUBWebView) { self.parent = parent }

        func loadDocument(path: String, fraction: Double, fragment: String?) {
            guard let view else { return }
            var components = URLComponents()
            components.scheme = "cloudreader-epub"
            components.host = "book"
            components.path = "/" + path
            guard let resourceURL = components.url else {
                parent.onError(EPUBError.unsafePath.localizedDescription)
                return
            }
            timeoutTask?.cancel()
            documentID = UUID()
            let expectedDocument = documentID
            configurationID = UUID()
            loadedPath = path
            activeNavigation = nil
            isReady = false
            pendingLoadNotification = false
            restoreFraction = fraction
            restoreFragment = fragment
            lastNavigationID = parent.navigationID
            appearanceKey = ""
            let load = { [weak self, weak view] in
                guard let self, let view, self.documentID == expectedDocument else { return }
                self.activeNavigation = view.load(URLRequest(url: resourceURL))
            }
            if let readerView = view as? MacReaderWKWebView {
                readerView.holdCurrentPage(then: load)
            } else {
                load()
            }
        }

        func cancelPresentation() {
            documentID = UUID()
            configurationID = UUID()
            timeoutTask?.cancel()
            (view as? MacReaderWKWebView)?.discardHeldPage()
        }

        func turnPage(_ direction: Int) {
            guard isReady, parent.pageLayoutRaw != "scroll", let view else { return }
            view.callAsyncJavaScript(
                "return window.cloudReader.turnPage(direction);",
                arguments: ["direction": direction],
                in: nil,
                in: .defaultClient
            ) { [weak self] result in
                guard let self, self.isReady else { return }
                if case let .failure(error) = result, (error as NSError).code != NSURLErrorCancelled {
                    self.parent.onError(error.localizedDescription)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            activeNavigation = navigation
            isReady = false
            pendingLoadNotification = false
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self else { return }
                webView.stopLoading()
                self.failed(NSError(domain: "CloudReader.EPUB", code: 1, userInfo: [NSLocalizedDescriptionKey: "This chapter took too long to open. Try again or import another copy of the book."]))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard activeNavigation === navigation else { return }
            timeoutTask?.cancel()
            appearanceKey = ""
            pendingLoadNotification = true
            applyAppearance(restoring: restoreFraction, fragment: restoreFragment)
        }

        @discardableResult
        func applyAppearance(restoring fraction: Double? = nil, fragment: String? = nil) -> Bool {
            guard let view else { return false }
            let foreground = Self.cssColor(parent.foreground, view: view)
            let background = Self.cssColor(parent.background, view: view)
            let family: String
            switch parent.fontRaw {
            case "systemSans": family = "-apple-system, sans-serif"
            case "rounded": family = "ui-rounded, -apple-system, sans-serif"
            case "georgia": family = "Georgia, serif"
            case "palatino": family = "Palatino, serif"
            case "avenir": family = "'Avenir Next', sans-serif"
            case "monospaced": family = "ui-monospace, monospace"
            default: family = "ui-serif, Georgia, serif"
            }
            let layout = ReaderPageLayout(rawValue: parent.pageLayoutRaw) ?? .scroll
            let font = ReaderFont(rawValue: parent.fontRaw) ?? .systemSerif
            let size = CGFloat(parent.fontSize)
            let metrics = ReaderLayoutMetrics.resolve(viewport: parent.viewportSize, pageLayout: layout, font: font, fontSize: size)
            let native: NSFont
            switch font {
            case .systemSans: native = NSFont.systemFont(ofSize: size)
            case .rounded:
                let base = NSFont.systemFont(ofSize: size)
                native = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            case .georgia: native = NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
            case .palatino: native = NSFont(name: "Palatino", size: size) ?? NSFont.systemFont(ofSize: size)
            case .avenir: native = NSFont(name: "Avenir Next", size: size) ?? NSFont.systemFont(ofSize: size)
            case .monospaced: native = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case .systemSerif:
                let base = NSFont.systemFont(ofSize: size)
                native = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            }
            let lineHeight = (native.ascender - native.descender + native.leading + size * 0.26) / max(size, 1)
            let paged = layout != .scroll
            let width = max(parent.viewportSize.width, 1)
            let columnWidth = (width - metrics.gutter * CGFloat(metrics.effectiveColumnCount - 1)) / CGFloat(metrics.effectiveColumnCount)
            let css = """
            html { scroll-behavior:auto!important; overflow-anchor:none!important; width:\(width)px!important; min-height:100%; background:\(background)!important; color:\(foreground)!important; -webkit-text-size-adjust:none; }
            body { color:\(foreground)!important; background:\(background)!important; font-family:\(family)!important; font-size:\(parent.fontSize)px!important; font-weight:400!important; line-height:\(lineHeight)!important; margin:0 auto!important; padding:0 \(metrics.horizontalMargin)px!important; box-sizing:border-box; overflow-wrap:anywhere; }
            html body * { color:inherit!important; font-family:inherit!important; font-size:inherit!important; font-weight:inherit!important; line-height:inherit!important; background-color:transparent!important; background-image:none!important; max-width:100%!important; box-sizing:border-box!important; }
            p, li, blockquote, dd { width:auto!important; text-indent:0!important; margin-inline-start:0!important; margin-inline-end:0!important; } html body p { margin-block:0 \(parent.fontSize * 0.55)px!important; }
            html body h1,html body h2,html body h3,html body h4,html body h5,html body h6,html body strong,html body b,html body th { font-weight:600!important; } html body h1{font-size:1.7em!important} html body h2{font-size:1.45em!important} html body h3{font-size:1.25em!important} html body h4,html body h5,html body h6{font-size:1.1em!important}
            img,svg,video,canvas,table{max-width:100%!important;height:auto;object-fit:contain} pre,code{white-space:pre-wrap!important;overflow-wrap:anywhere!important} a{text-decoration:underline}
            [style*="width"],[width]{max-width:100%!important}
            \(paged ? "html { height:100%!important; overflow-x:auto!important; overflow-y:hidden!important; } body { height:100vh!important; width:\(width)px!important; padding:0!important; overflow:visible!important; column-count:auto!important; column-width:\(columnWidth)px!important; column-gap:\(metrics.gutter)px!important; column-fill:auto!important; } html body > :not(img):not(svg):not(video):not(canvas) { margin-inline:\(metrics.horizontalMargin)px!important; }" : "body { width:auto!important; max-width:\(metrics.maximumProseWidth + metrics.horizontalMargin * 2)px!important; margin:0 auto!important; }")
            """
            let key = "\(css)|height:\(parent.viewportSize.height)"
            let changesLayout = appearanceKey != key
            guard changesLayout || fraction != nil || fragment != nil else { return false }
            appearanceKey = key
            let identifier = UUID()
            let expectedDocument = documentID
            let requestedNavigation = lastNavigationID
            let arguments: [String: Any] = [
                "css": css,
                "paged": paged,
                "fraction": fraction as Any? ?? NSNull(),
                "fragment": fragment as Any? ?? NSNull(),
                "viewportWidth": width, "columns": metrics.effectiveColumnCount, "gutter": metrics.gutter,
                "configurationID": identifier.uuidString
            ]
            let expectedPath = loadedPath
            configurationID = identifier
            // Position-only navigation must not replace CSS: WebKit can briefly
            // reset its columns/scroll offset when an identical sheet is replaced.
            let script = changesLayout
                ? "return await window.cloudReader.configure(css, paged, fraction, fragment, viewportWidth, columns, gutter, configurationID);"
                : "return await window.cloudReader.navigate(fraction, fragment, configurationID);"
            view.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                in: .defaultClient
            ) { [weak self] result in
                guard let self, self.documentID == expectedDocument, self.loadedPath == expectedPath,
                      self.configurationID == identifier else { return }
                switch result {
                case .success:
                    if self.pendingLoadNotification {
                        self.finishInitialLoad(configuration: identifier, navigation: requestedNavigation)
                    }
                case .failure(let error):
                    self.failed(error)
                }
            }
            return true
        }

        private func finishInitialLoad(configuration: UUID, navigation: UUID?) {
            guard let view, pendingLoadNotification, configurationID == configuration else { return }
            if lastNavigationID != navigation {
                applyAppearance(restoring: restoreFraction, fragment: restoreFragment)
                return
            }
            // Geometry/appearance can also change during loading. Complete that
            // reflow before revealing the new document.
            if applyAppearance() { return }
            view.callAsyncJavaScript(
                "return await window.cloudReader.reveal(configurationID);",
                arguments: ["configurationID": configuration.uuidString], in: nil, in: .defaultClient
            ) { [weak self] result in
                guard let self, self.pendingLoadNotification, self.configurationID == configuration else { return }
                if case let .failure(error) = result {
                    self.failed(error)
                    return
                }
                if self.lastNavigationID != navigation {
                    self.applyAppearance(restoring: self.restoreFraction, fragment: self.restoreFragment)
                    return
                }
                if self.applyAppearance() { return }
                (view as? MacReaderWKWebView)?.revealCurrentPage()
                self.pendingLoadNotification = false
                self.isReady = true
                self.parent.onLoaded()
                // Initial reports were suppressed while the outgoing snapshot
                // was visible. Publish only the final, presented destination.
                view.callAsyncJavaScript("window.cloudReader.report();", arguments: [:], in: nil, in: .defaultClient) { _ in }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isReady, message.frameInfo.isMainFrame,
                  let frameURL = message.frameInfo.request.url,
                  let frame = URLComponents(url: frameURL, resolvingAgainstBaseURL: false),
                  frame.scheme == "cloudreader-epub", frame.host == "book",
                  String(frame.path.dropFirst()) == loadedPath,
                  let payload = message.body as? [String: Any],
                  payload["configurationID"] as? String == configurationID.uuidString else { return }
            let isSpineChapter = parent.publication.chapters.contains { $0.path == loadedPath }
            if isSpineChapter, let fraction = payload["progress"] as? Double, fraction.isFinite {
                parent.onProgress(min(max(fraction, 0), 1))
            }
            if isSpineChapter, payload["kind"] as? String == "location" {
                parent.onNavigationState(payload["page"] as? Int, payload["pages"] as? Int, (payload["progress"] as? Double) ?? 0)
            }
            if isSpineChapter, payload["kind"] as? String == "boundary", let direction = payload["direction"] as? Int {
                parent.onChapterBoundary(direction > 0 ? 1 : -1)
            }
            if let selection = payload["selection"] as? String {
                parent.onSelection(String(selection.prefix(18_000)))
            }
            if payload["kind"] as? String == "tap" { parent.onContentTap() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let targetURL = navigationAction.request.url,
                  targetURL.scheme == "cloudreader-epub",
                  targetURL.host == "book" else {
                decisionHandler(.cancel)
                return
            }
            let path = String(targetURL.path.dropFirst())
            if navigationAction.navigationType == .linkActivated {
                let fragment = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)?.fragment
                let destination = EPUBNavigationPolicy.destination(
                    path: path,
                    fragment: fragment,
                    currentPath: loadedPath,
                    chapters: parent.publication.chapters,
                    mediaTypes: parent.publication.mediaTypes
                )
                switch destination {
                case let .chapter(index, targetFragment):
                    decisionHandler(.cancel)
                    parent.onNavigate(index, targetFragment)
                case let .document(path, fragment):
                    decisionHandler(.cancel)
                    nonSpineDocumentPath = path
                    loadDocument(path: path, fraction: 0, fragment: fragment)
                case nil:
                    decisionHandler(.allow)
                }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(EPUBError.invalidBook) }

        private func failed(_ error: Error, navigation: WKNavigation? = nil) {
            if let navigation, activeNavigation !== navigation { return }
            timeoutTask?.cancel()
            if (error as NSError).code != NSURLErrorCancelled {
                cancelPresentation()
                isReady = false
                parent.onError(error.localizedDescription)
            }
        }

        private static func cssColor(_ color: Color, view: NSView) -> String {
            var rgb: NSColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                rgb = NSColor(color).usingColorSpace(.deviceRGB)
            }
            guard let rgb else { return "rgb(255,255,255)" }
            return "rgb(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255)))"
        }

        deinit { timeoutTask?.cancel() }
    }

    private static let viewportScript = """
    (() => {
      // Preserve layout measurement while preventing a publisher-style/first-page
      // paint before the reader has restored the requested location.
      const namespace = document.documentElement.namespaceURI;
      const gate = namespace === 'http://www.w3.org/2000/svg'
        ? document.createElementNS(namespace, 'style') : document.createElement('style');
      gate.id = 'cloudreader-pending-layout';
      gate.textContent = ':root { opacity:0!important; }';
      (document.head || document.documentElement).appendChild(gate);
      let meta = document.querySelector('meta[name="viewport"]');
      if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; (document.head || document.documentElement).appendChild(meta); }
      meta.content = 'width=device-width, initial-scale=1';
    })();
    """

    private static let readerScript = """
    (() => {
      let paged = false, restoring = true, configured = false, timer, previous = 0, spreadWidth = 1, pageGap = 0, pagesPerView = 1, suppressScrollUntil = 0, cachedPageCount = null;
      let desired = null, restoreVersion = 0, passage = null, configurationID = null;
      let columnPitch = 1, viewportWidth = 1, cachedContentMetrics = null;
      const post = payload => webkit.messageHandlers.reader.postMessage({...payload, configurationID});
      const scrollInstantly = (left, top) => scrollTo({left, top, behavior:'instant'});
      const waiters = [];
      let pointerStart = null;
      const root = () => document.scrollingElement || document.documentElement;
      const pageCount = () => {
        const content = document.body || document.documentElement;
        const metrics = [content.scrollWidth, content.scrollHeight, columnPitch, pagesPerView].join('|');
        if (cachedPageCount !== null && cachedContentMetrics === metrics) return cachedPageCount;
        cachedContentMetrics = metrics;
        if (!paged) return cachedPageCount = Math.max(1, Math.ceil((root().scrollHeight + 1) / Math.max(innerHeight, 1)));
        let finalColumn = 0;
        const include = rect => {
          if (rect.width <= 0 || rect.height <= 0) return;
          const right = Math.max(0, rect.right + scrollX - 1);
          finalColumn = Math.max(finalColumn, Math.floor(right / columnPitch));
        };
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          if (!walker.currentNode.nodeValue.trim()) continue;
          const range = document.createRange(); range.selectNodeContents(walker.currentNode);
          Array.from(range.getClientRects()).forEach(include);
        }
        // Image-only chapters and trailing illustrations also occupy columns.
        content.querySelectorAll('img,svg,video,canvas,table,hr').forEach(element => {
          Array.from(element.getClientRects()).forEach(include);
        });
        return cachedPageCount = finalColumn + 1;
      };
      const distance = () => {
        if (!paged) return Math.max(0, root().scrollHeight - innerHeight);
        const maximum = Math.max(0, Math.ceil(pageCount() / pagesPerView) - 1) * spreadWidth;
        if (document.body) {
          // An odd final page still needs a full viewport of scrollable space.
          // Keep the extent marker outside the columns so it adds no content page.
          let marker = document.getElementById('cloudreader-page-extent');
          if (!marker) {
            marker = document.createElement('div');
            marker.id = 'cloudreader-page-extent';
            marker.setAttribute('aria-hidden', 'true');
            marker.style.cssText = 'position:absolute!important;top:0!important;width:1px!important;height:1px!important;opacity:0!important;pointer-events:none!important;';
            document.documentElement.appendChild(marker);
          }
          const left = Math.ceil(maximum + innerWidth) - 1 + 'px';
          if (marker.style.left !== left) marker.style.setProperty('left', left, 'important');
        }
        return maximum;
      };
      const position = () => {
        const extent = distance();
        return extent > 1 ? Math.max(0, Math.min(1, (paged ? scrollX : scrollY) / extent)) : 0;
      };
      const restore = fraction => {
        const extent = distance();
        scrollInstantly(paged ? Math.round(fraction * extent / Math.max(spreadWidth, 1)) * spreadWidth : 0, paged ? 0 : fraction * extent);
      };
      const findPassage = value => {
        if (!value) return null;
        const quote = typeof value === 'string' ? value : value.text;
        const targetOccurrence = typeof value === 'string' ? 0 : (value.occurrence || 0);
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        let occurrence = 0;
        while (walker.nextNode()) {
          const node = walker.currentNode;
          let offset = -1;
          while ((offset = node.nodeValue.indexOf(quote, offset + 1)) >= 0) {
            if (occurrence++ === targetOccurrence) { const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + 1); return range; }
          }
        }
        return null;
      };
      const capturePassage = () => {
        const margin = Math.min(42, Math.max(22, innerWidth * 0.045));
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        let targetNode = null, targetOffset = 0;
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (node.nodeValue.trim().length < 24) continue;
          const range = document.createRange(); range.selectNodeContents(node);
          const rect = Array.from(range.getClientRects()).find(r => r.width > 0 && r.height > 0 && r.right > margin && r.left < innerWidth / pagesPerView && r.bottom > 0 && r.top < innerHeight);
          if (!rect) continue;
          const caret = document.caretRangeFromPoint(Math.max(margin + 1, rect.left + 1), Math.max(1, rect.top + Math.min(rect.height / 2, 8)));
          targetNode = node;
          targetOffset = caret && caret.startContainer === node ? caret.startOffset : 0;
          break;
        }
        if (!targetNode) return passage;
        const remainder = targetNode.nodeValue.slice(targetOffset);
        targetOffset += remainder.length - remainder.trimStart().length;
        const quote = targetNode.nodeValue.slice(targetOffset, targetOffset + 56);
        if (!quote) return passage;
        const all = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        let occurrence = 0;
        while (all.nextNode()) {
          const node = all.currentNode;
          let offset = -1;
          while ((offset = node.nodeValue.indexOf(quote, offset + 1)) >= 0) {
            if (node === targetNode && offset >= targetOffset) break;
            occurrence++;
          }
          if (node === targetNode) break;
        }
        const range = document.createRange(); range.setStart(targetNode, targetOffset); range.setEnd(targetNode, Math.min(targetOffset + 1, targetNode.length));
        const rect = range.getBoundingClientRect();
        return {text:quote, occurrence, x:rect.left, y:rect.top};
      };
      const requestRestore = (fraction, fragment, passageAnchor = null, reflow = false) => {
        const request = {fraction:Math.max(0, Math.min(1, fraction)), fragment, passageAnchor, version:++restoreVersion};
        desired = request;
        // Keep the desired position even when the first, zero-sized viewport
        // has no scrollable extent. A later resize must not replace it with 0.
        previous = request.fraction;
        restoring = true;
        suppressScrollUntil = Date.now() + 180;
        clearTimeout(timer);
        let lastMetrics = '', stableFrames = 0, attempts = 0;
        const step = () => {
          if (request.version !== restoreVersion) return;
          // Initial images/fonts can settle after configure's first measurement.
          if (reflow && paged) cachedPageCount = null;
          const anchor = request.fragment === null ? null : document.getElementById(request.fragment) || document.getElementsByName(request.fragment)[0];
          const passageRange = anchor ? null : findPassage(request.passageAnchor);
          if (anchor) {
            if (paged) {
              const rect = anchor.getClientRects()[0] || anchor.getBoundingClientRect();
              scrollInstantly(Math.max(0, Math.floor((scrollX + rect.left) / spreadWidth)) * spreadWidth, 0);
            } else anchor.scrollIntoView({block:'start', inline:'start', behavior:'instant'});
          }
          else if (passageRange) {
            const rect = passageRange.getBoundingClientRect();
            if (paged) scrollInstantly(Math.floor((scrollX + rect.left) / Math.max(spreadWidth, 1)) * spreadWidth, 0);
            else scrollInstantly(0, Math.max(0, scrollY + rect.top - request.passageAnchor.y));
            passage = request.passageAnchor;
          }
          else restore(request.fraction);
          const e = root(), metrics = [innerWidth, innerHeight, e.scrollWidth, e.scrollHeight].join('|');
          const reachedTarget = anchor || passageRange || distance() <= 1 || Math.abs(position() - request.fraction) < 0.005;
          stableFrames = metrics === lastMetrics && reachedTarget ? stableFrames + 1 : 0;
          lastMetrics = metrics;
          if ((innerWidth > 0 && innerHeight > 0 && stableFrames >= 3) || ++attempts >= 90) {
            previous = anchor || passageRange ? position() : request.fraction;
            desired = null;
            restoring = false;
            report();
            waiters.splice(0).forEach(resolve => resolve());
          } else requestAnimationFrame(step);
        };
        requestAnimationFrame(() => requestAnimationFrame(step));
      };
      const report = () => {
        const extent = distance(), progress = position(), pages = pageCount();
        const spread = Math.min(Math.max(0, Math.round(scrollX / spreadWidth)), Math.ceil(pages / pagesPerView) - 1);
        const page = paged ? spread * pagesPerView + 1 : Math.min(Math.max(0, Math.floor(scrollY / Math.max(innerHeight, 1))), pages - 1);
        passage = capturePassage();
        post({kind:'location', progress, page, pages});
      };
      const turnPage = direction => {
        if (!paged) return;
        const maximum = distance(), current = Math.round(scrollX / Math.max(spreadWidth, 1));
        const next = current + Math.sign(direction);
        const target = next * spreadWidth;
        if (target < -1 || target > maximum + 1) { post({kind:'boundary', direction:Math.sign(direction)}); return; }
        scrollInstantly(Math.min(Math.max(target, 0), maximum), 0);
      };
      window.cloudReader = { turnPage, report,
        navigate(fraction, fragment, identifier) {
          configurationID = identifier;
          const ready = new Promise(resolve => waiters.push(resolve));
          requestRestore(fraction === null ? position() : fraction, fragment);
          return ready;
        },
        async reveal(identifier) {
          if (configurationID !== identifier) return;
          document.getElementById('cloudreader-pending-layout')?.remove();
          // Let WebKit composite the restored content before removing its native cover.
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        },
        configure(css, horizontal, fraction, fragment, measuredWidth, columnCount, measuredGap, identifier) {
        configurationID = identifier;
        const target = fraction === null ? (desired ? desired.fraction : position()) : fraction;
        const keepPassage = fraction === null && fragment === null ? (passage || capturePassage()) : null;
        paged = horizontal;
        viewportWidth = Math.max(measuredWidth || innerWidth, 1);
        pageGap = measuredGap || 0;
        pagesPerView = Math.max(columnCount || 1, 1);
        cachedPageCount = null;
        document.getElementById('cloudreader-page-extent')?.remove();
        document.querySelectorAll('[style]').forEach(element => {
          ['font-family','font-size','font-weight','line-height','text-indent','color','background-color','background-image','margin-left','margin-right','margin-inline-start','margin-inline-end'].forEach(property => element.style.removeProperty(property));
        });
        let style = document.getElementById('cloudreader-style');
        if (!style) {
          const namespace = document.documentElement.namespaceURI;
          style = namespace === 'http://www.w3.org/2000/svg' ? document.createElementNS(namespace, 'style') : document.createElement('style');
          style.id = 'cloudreader-style';
          (document.head || document.documentElement).appendChild(style);
        }
        if (style.textContent !== css) style.textContent = css;
        const bodyWidth = document.body ? document.body.getBoundingClientRect().width : viewportWidth;
        const columnWidth = Math.max(1, (bodyWidth - pageGap * (pagesPerView - 1)) / pagesPerView);
        columnPitch = columnWidth + pageGap;
        // Overflowing columns retain their gutter after the last visible column:
        // a complete spread advances by bodyWidth + gutter, not bodyWidth.
        spreadWidth = columnPitch * pagesPerView;
        distance();
        configured = true;
        const ready = new Promise(resolve => waiters.push(resolve));
        requestRestore(target, fragment, keepPassage, true);
        return ready;
      }};
      addEventListener('scroll', () => {
        if (restoring || Date.now() < suppressScrollUntil) return;
        previous = position();
        clearTimeout(timer);
        timer = setTimeout(() => { if (!restoring) { post({progress:position()}); report(); } }, 100);
      }, {passive:true});
      document.addEventListener('selectionchange', () => post({selection:String(getSelection())}));
      document.addEventListener('keydown', event => { if(!paged||!getSelection().isCollapsed||event.metaKey||event.ctrlKey||event.altKey)return;let d=0;if(event.key==='ArrowRight'||event.key==='PageDown'||event.key===' ')d=1;else if(event.key==='ArrowLeft'||event.key==='PageUp')d=-1;else return;event.preventDefault();turnPage(d);});
      let tapTimer=null;
      document.addEventListener('click', event => {
        if (event.detail > 1) { clearTimeout(tapTimer); tapTimer=null; return; }
        if (pointerStart && (Math.abs(event.clientX - pointerStart.x) > 8 || Math.abs(event.clientY - pointerStart.y) > 8)) { pointerStart=null; return; }
        pointerStart=null;
        if (String(getSelection()).trim()) return;
        const target=event.target;
        if (target && target.closest && target.closest('a,button,input,select,textarea,video,audio,[contenteditable=true]')) return;
        clearTimeout(tapTimer);
        tapTimer=setTimeout(()=>{tapTimer=null;if(!String(getSelection()).trim())post({kind:'tap'});},\(max(NSEvent.doubleClickInterval * 1000, 260)));
      }, {passive:true});
      document.addEventListener('pointerdown', event => {
        if (event.isPrimary) pointerStart = {x:event.clientX, y:event.clientY};
      }, {passive:true});
      document.addEventListener('pointercancel', () => { pointerStart=null; clearTimeout(tapTimer); tapTimer=null; }, {passive:true});
    })();
    """
}

final class MacReaderWKWebView: WKWebView {
    var pageLayoutRaw = "scroll"
    var onPageTurn: ((Int) -> Void)?
    private var horizontalDelta: CGFloat = 0
    private var pendingTurn: DispatchWorkItem?
    private var gestureTurned = false
    private var hasPresentedPage = false
    private var navigationSnapshot: NSImageView?
    private var snapshotID = UUID()

    func holdCurrentPage(then load: @escaping () -> Void) {
        snapshotID = UUID()
        let identifier = snapshotID
        guard hasPresentedPage, navigationSnapshot == nil else { load(); return }
        takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, self.snapshotID == identifier else { return }
            if let image {
                let cover = NSImageView(frame: self.bounds)
                cover.identifier = NSUserInterfaceItemIdentifier("reader.navigationSnapshot")
                cover.image = image
                cover.imageScaling = .scaleAxesIndependently
                cover.autoresizingMask = [.width, .height]
                cover.setAccessibilityElement(false)
                self.addSubview(cover, positioned: .above, relativeTo: nil)
                self.navigationSnapshot = cover
            }
            load()
        }
    }

    func revealCurrentPage() {
        hasPresentedPage = true
        navigationSnapshot?.removeFromSuperview()
        navigationSnapshot = nil
    }

    func discardHeldPage() {
        snapshotID = UUID()
        navigationSnapshot?.removeFromSuperview()
        navigationSnapshot = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard pageLayoutRaw != "scroll",
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              onPageTurn != nil else {
            super.scrollWheel(with: event)
            return
        }
        // Momentum is the tail of the same physical swipe; consuming it must
        // not trigger another spread turn.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            pendingTurn?.cancel()
            horizontalDelta = 0
            gestureTurned = false
        }
        guard !gestureTurned else { return }
        horizontalDelta += event.scrollingDeltaX
        pendingTurn?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let delta = self.horizontalDelta
            self.horizontalDelta = 0
            guard abs(delta) >= 1 else { return }
            self.gestureTurned = true
            self.onPageTurn?(delta < 0 ? 1 : -1)
        }
        pendingTurn = work
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        DispatchQueue.main.asyncAfter(deadline: .now() + (ended ? .milliseconds(0) : .milliseconds(220)), execute: work)
        if event.phase.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(320)) { [weak self] in
                self?.gestureTurned = false
                self?.horizontalDelta = 0
            }
        }
    }

    deinit { pendingTurn?.cancel() }
}

private final class MacEPUBResourceHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let mediaTypes: [String: String]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(root: URL, mediaTypes: [String: String]) {
        self.root = root
        self.mediaTypes = mediaTypes
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url, requestURL.host == "book" else {
            urlSchemeTask.didFailWithError(EPUBError.unsafePath)
            return
        }
        let root = root
        let mediaTypes = mediaTypes
        tasks[id] = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Data, String), Error> in
                do {
                    let path = String(requestURL.path.dropFirst())
                    let resource = try EPUBResourcePolicy.resourceURL(root: root, relativePath: path)
                    let source = try Data(contentsOf: resource, options: .mappedIfSafe)
                    let fallback = UTType(filenameExtension: resource.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
                    let prepared = try EPUBResourcePolicy.prepare(data: source, resourceURL: resource, requestPath: path, mediaTypes: mediaTypes, fallbackMIMEType: fallback)
                    return .success((prepared.data, prepared.mimeType))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled, let self, self.tasks.removeValue(forKey: id) != nil else { return }
            switch result {
            case .success(let (data, mime)):
                urlSchemeTask.didReceive(URLResponse(
                    url: requestURL,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: mime == "text/html" ? "utf-8" : nil
                ))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error):
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
