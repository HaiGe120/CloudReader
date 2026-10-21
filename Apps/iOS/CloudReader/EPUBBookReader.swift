import SwiftUI
import CloudReaderCore
import UniformTypeIdentifiers
import WebKit

struct EPUBBookReader: View {
    let bookID: UUID
    let url: URL
    var sourceFormat: BookFormat = .epub
    let progress: Double
    let pageLayout: ReaderPageLayout
    let font: ReaderFont
    let fontSize: CGFloat
    let palette: ReaderPalette
    var isChromeVisible: Bool = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }
    var onContentTap: () -> Void = {}
    var onSelectedTextChanged: (String) -> Void = { _ in }
    let onAskAI: (String) -> Void

    @State private var publication: EPUBPublication?
    @State private var chapter = 0
    @State private var chapterProgress = 0.0
    @State private var loadError: String?
    @State private var isLoadingChapter = true
    @State private var selectedText = ""
    @State private var reloadID = UUID()
    @State private var loadedSourceURL: URL?
    @State private var targetFragment: String?
    @State private var presentedNote: EPUBNote?
    @State private var navigationRequestID = UUID()
    @State private var viewportSize: CGSize = .zero
    @State private var lastConsumedRequestID: UUID?
    @State private var currentPage: Int?
    @State private var currentPageCount: Int?
    @State private var pendingPageTurn: Int?

    var body: some View {
        let renderedChapter = chapter
        Group {
            if let publication, loadedSourceURL == url {
                GeometryReader { geometry in
                    ZStack {
                        EPUBWebView(
                            publication: publication, chapter: chapter, initialProgress: chapterProgress,
                            pageLayout: pageLayout, font: font, fontSize: fontSize, palette: palette,
                            onProgress: { fraction in
                                guard chapter == renderedChapter else { return }
                                chapterProgress = fraction
                                let value = EPUBPublication.progress(chapter: chapter, fraction: fraction, chapterCount: publication.chapters.count)
                                onNavigationStateChanged(navigationState(publication: publication, progress: value, page: nil, pages: nil))
                            },
                            onSelection: { text in
                                guard chapter == renderedChapter else { return }
                                selectedText = text
                                onSelectedTextChanged(text)
                            },
                            onNavigate: { index, fragment in
                                guard chapter == renderedChapter else { return }
                                navigate(to: index, in: publication, fragment: fragment)
                            },
                            onLoaded: { guard chapter == renderedChapter else { return }; isLoadingChapter = false },
                            onError: { guard chapter == renderedChapter else { return }; loadError = $0; isLoadingChapter = false },
                            targetFragment: targetFragment,
                            onOpenNote: { path, fragment in
                                guard chapter == renderedChapter else { return }
                                presentedNote = EPUBNote(path: path, fragment: fragment)
                            },
                            navigationRequestID: navigationRequestID,
                            viewportSize: geometry.size,
                            isChromeVisible: isChromeVisible,
                            onContentTap: onContentTap,
                            onNavigationState: { page, pages, fraction in
                                guard chapter == renderedChapter else { return }
                                currentPage = page
                                currentPageCount = pages
                                if page != nil {
                                    pendingPageTurn = nil
                                    if pages != nil { isLoadingChapter = false }
                                }
                                let value = EPUBPublication.progress(chapter: chapter, fraction: fraction, chapterCount: publication.chapters.count)
                                onNavigationStateChanged(navigationState(publication: publication, progress: value,
                                    page: pageLayout == .scroll ? nil : page,
                                    pages: pageLayout == .scroll ? nil : pages))
                            }
                        )
                        .id(EPUBSourceRequest(url: url, reloadID: reloadID))
                        if isLoadingChapter {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Opening chapter…")
                            }
                                .padding()
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Opening chapter")
                                .accessibilityIdentifier("reader.loading")
                        }
                    }
                    .onAppear { viewportSize = geometry.size }
                    .onChange(of: geometry.size) { viewportSize = geometry.size }
                }
            } else if loadError == nil {
                ProgressView("Preparing book…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(Color(uiColor: palette.foreground))
        .background(Color(uiColor: palette.background))
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
                        reloadID = UUID()
                    }.buttonStyle(.bordered)
                }
                .background(Color(uiColor: palette.background))
            }
        }
        .sheet(item: $presentedNote) { note in
            if let publication {
                EPUBNoteSheet(
                    publication: publication, note: note,
                    pageLayout: pageLayout, font: font, fontSize: fontSize, palette: palette,
                    onNavigateToChapter: { index, fragment in
                        presentedNote = nil
                        navigate(to: index, in: publication, fragment: fragment)
                    }
                )
            }
        }
        .task(id: EPUBSourceRequest(url: url, reloadID: reloadID)) {
            if loadedSourceURL != url {
                publication = nil
                loadError = nil
                selectedText = ""
                targetFragment = nil
                isLoadingChapter = true
                loadedSourceURL = url
            }
            guard publication == nil else { return }
            do {
                let loaded: EPUBPublication
                if sourceFormat == .fb2 {
                    loaded = try await FB2Loader.shared.open(url: url, bookID: bookID)
                } else if sourceFormat == .mobi || sourceFormat == .azw3 {
                    loaded = try await KindleLoader.shared.open(url: url, bookID: bookID)
                } else {
                    loaded = try await EPUBLoader.shared.open(url: url, bookID: bookID)
                }
                try Task.checkCancellation()
                let location = EPUBPublication.location(progress: progress, chapterCount: loaded.chapters.count)
                chapter = location.chapter
                chapterProgress = location.fraction
                publication = loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
        .onAppear { consume(navigationRequest) }
        .onChange(of: navigationRequest) { consume(navigationRequest) }
        .onChange(of: publication != nil) {
            if publication != nil { consume(navigationRequest) }
        }
        .onChange(of: viewportSize) {
            // Keep the last measured page state until WebKit publishes reflowed
            // metrics; hiding controls must not replace page status with percent.
            onNavigationStateChanged(navigationState(publication: publication, progress: progress,
                page: pageLayout == .scroll ? nil : currentPage, pages: currentPageCount))
        }
    }

    private func navigate(to index: Int, in publication: EPUBPublication, fragment: String? = nil) {
        guard publication.chapters.indices.contains(index) else { return }
        let changesChapter = index != chapter
        guard changesChapter || fragment != nil else { return }
        chapter = index
        if changesChapter { chapterProgress = 0; currentPage = nil; currentPageCount = nil; pendingPageTurn = nil }
        targetFragment = fragment
        navigationRequestID = UUID()
        selectedText = ""
        onSelectedTextChanged("")
        isLoadingChapter = changesChapter
    }

    private func consume(_ request: ReaderNavigationRequest?) {
        guard let request, request.id != lastConsumedRequestID, let publication else { return }
        lastConsumedRequestID = request.id
        switch request.command {
        case .previous:
            let stride = ReaderLayoutMetrics.resolve(viewport: viewportSize, pageLayout: pageLayout, font: font, fontSize: fontSize).effectiveColumnCount
            let firstPage = pageLayout == .scroll ? 0 : 1
            if let count = currentPageCount, let page = effectivePage(count: count), page > firstPage {
                let destination = max(page - (pageLayout == .scroll ? 1 : stride), firstPage)
                pendingPageTurn = destination
                chapterProgress = Double(max(destination - firstPage, 0)) / Double(max(count - 1, 1)); navigationRequestID = UUID()
            } else if currentPage != nil || currentPageCount != nil {
                navigate(to: chapter - 1, in: publication)
            } else if chapterProgress > 0.002 { navigationRequestID = UUID(); chapterProgress = max(0, chapterProgress - 0.08) }
            else { navigate(to: chapter - 1, in: publication) }
        case .next:
            let stride = ReaderLayoutMetrics.resolve(viewport: viewportSize, pageLayout: pageLayout, font: font, fontSize: fontSize).effectiveColumnCount
            let increment = pageLayout == .scroll ? 1 : stride
            let firstPage = pageLayout == .scroll ? 0 : 1
            let current = currentPage ?? (currentPageCount.flatMap { effectivePage(count: $0) } ?? firstPage)
            let destination = current + increment
            if currentPageCount != nil, let count = currentPageCount, destination < count + (pageLayout == .scroll ? 0 : 1) {
                pendingPageTurn = destination
                chapterProgress = Double(max(destination - (pageLayout == .scroll ? 0 : 1), 0)) / Double(max(count - 1, 1)); navigationRequestID = UUID()
            } else if currentPage != nil || currentPageCount != nil {
                navigate(to: chapter + 1, in: publication)
            } else if chapterProgress < 0.998 { navigationRequestID = UUID(); chapterProgress = min(1, chapterProgress + 0.08) }
            else { navigate(to: chapter + 1, in: publication) }
        case .previousChapter: navigate(to: chapter - 1, in: publication)
        case .nextChapter: navigate(to: chapter + 1, in: publication)
        case .chapter(let index): navigate(to: index, in: publication)
        case .seek(let value):
            pendingPageTurn = nil
            let location = EPUBPublication.location(progress: value, chapterCount: publication.chapters.count)
            if location.chapter != chapter { navigate(to: location.chapter, in: publication) }
            chapterProgress = location.fraction
            navigationRequestID = UUID()
        }
    }

    private func navigationState(publication: EPUBPublication?, progress: Double, page: Int?, pages: Int?) -> ReaderNavigationState {
        let titles = publication?.chapters.map(\.title) ?? []
        let global = min(max(progress, 0), 1)
        return ReaderNavigationState(progress: global,
            pageRange: page.map { index in
                let spreadSize = ReaderLayoutMetrics.resolve(viewport: viewportSize, pageLayout: pageLayout, font: font, fontSize: fontSize).effectiveColumnCount
                let first = min(index, pages ?? index)
                return first...max(first, min(index + spreadSize - 1, pages ?? index))
            },
            pageCount: pages, chapterIndex: publication == nil ? nil : chapter,
            chapterCount: publication?.chapters.count, chapterTitles: titles,
            canNavigatePrevious: (publication.map { _ in chapter > 0 } ?? false) || global > 0,
            canNavigateNext: (publication.map { chapter < $0.chapters.count - 1 } ?? false) || global < 1)
    }

    private func effectivePage(count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let pendingPageTurn { return min(max(pendingPageTurn, 0), count - 1) }
        if let currentPage { return min(max(currentPage, 0), count - 1) }
        let first = pageLayout == .scroll ? 0 : 1
        let estimate = Int((chapterProgress * Double(max(count - 1, 1))).rounded(.down)) + first
        return min(max(estimate, first), count - 1)
    }

}

private struct EPUBSourceRequest: Hashable {
    let url: URL
    let reloadID: UUID
}

private struct EPUBNote: Identifiable {
    let id = UUID()
    let path: String
    let fragment: String?
}

private struct EPUBNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let publication: EPUBPublication
    let pageLayout: ReaderPageLayout
    let font: ReaderFont
    let fontSize: CGFloat
    let palette: ReaderPalette
    let onNavigateToChapter: (Int, String?) -> Void
    @State private var note: EPUBNote
    @State private var isLoading = true
    @State private var loadError: String?

    init(
        publication: EPUBPublication, note: EPUBNote,
        pageLayout: ReaderPageLayout, font: ReaderFont, fontSize: CGFloat, palette: ReaderPalette,
        onNavigateToChapter: @escaping (Int, String?) -> Void
    ) {
        self.publication = publication
        self.pageLayout = pageLayout
        self.font = font
        self.fontSize = fontSize
        self.palette = palette
        self.onNavigateToChapter = onNavigateToChapter
        _note = State(initialValue: note)
    }

    var body: some View {
        let notePublication = EPUBPublication(
            rootURL: publication.rootURL, title: "Note",
            chapters: publication.chapters + [EPUBChapter(path: note.path, title: "Note")], mediaTypes: publication.mediaTypes
        )
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    EPUBWebView(
                    publication: notePublication, chapter: publication.chapters.count, initialProgress: 0,
                    pageLayout: pageLayout, font: font, fontSize: fontSize, palette: palette,
                    onProgress: { _ in }, onSelection: { _ in },
                    onNavigate: { index, fragment in
                        guard publication.chapters.indices.contains(index) else { return }
                        dismiss()
                        onNavigateToChapter(index, fragment)
                    },
                    onLoaded: { isLoading = false },
                    onError: { loadError = $0; isLoading = false },
                    targetFragment: note.fragment,
                    onOpenNote: { path, fragment in
                        loadError = nil
                        isLoading = true
                        note = EPUBNote(path: path, fragment: fragment)
                    },
                    navigationRequestID: note.id,
                    viewportSize: geometry.size
                    )
                    .id(note.id)
                    if isLoading { ProgressView("Opening note…") }
                    if let loadError {
                        ContentUnavailableView("Couldn't open note", systemImage: "doc.text", description: Text(loadError))
                            .background(Color(uiColor: palette.background))
                    }
                }
                .background(Color(uiColor: palette.background))
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct EPUBWebView: UIViewRepresentable {
    let publication: EPUBPublication
    let chapter: Int
    let initialProgress: Double
    let pageLayout: ReaderPageLayout
    let font: ReaderFont
    let fontSize: CGFloat
    let palette: ReaderPalette
    let onProgress: (Double) -> Void
    let onSelection: (String) -> Void
    let onNavigate: (Int, String?) -> Void
    let onLoaded: () -> Void
    let onError: (String) -> Void
    var targetFragment: String? = nil
    var onOpenNote: ((String, String?) -> Void)? = nil
    var navigationRequestID: UUID? = nil
    var viewportSize: CGSize = .zero
    var isChromeVisible = true
    var onContentTap: () -> Void = {}
    var onNavigationState: (Int?, Int?, Double) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(EPUBResourceHandler(root: publication.rootURL, mediaTypes: publication.mediaTypes), forURLScheme: "cloudreader-epub")
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "reader")
        let viewportScript = WKUserScript(source: Self.viewportScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(viewportScript)
        let script = WKUserScript(source: Self.readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(script)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.decelerationRate = .fast
        view.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.handleReaderPan(_:)))
        context.coordinator.view = view
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        view.backgroundColor = palette.background
        view.scrollView.backgroundColor = palette.background
        view.scrollView.isPagingEnabled = pageLayout != .scroll
        let path = publication.chapters[chapter].path
        if context.coordinator.loadedPath != path {
            context.coordinator.loadedPath = path
            context.coordinator.isReady = false
            context.coordinator.restoreFraction = initialProgress
            context.coordinator.lastNavigationRequestID = navigationRequestID
            var components = URLComponents()
            components.scheme = "cloudreader-epub"
            components.host = "book"
            components.path = "/" + path
            if let url = components.url { view.load(URLRequest(url: url)) }
        } else if context.coordinator.isReady {
            if context.coordinator.lastNavigationRequestID != navigationRequestID {
                context.coordinator.lastNavigationRequestID = navigationRequestID
                context.coordinator.applyAppearance(restoring: initialProgress, fragment: targetFragment)
            } else {
                context.coordinator.applyAppearance()
            }
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EPUBWebView
        weak var view: WKWebView?
        var loadedPath: String?
        private var activeNavigation: WKNavigation?
        var isReady = false
        var restoreFraction = 0.0
        var lastNavigationRequestID: UUID?
        private var appearanceKey = ""
        private var configurationID = UUID()
        private var pendingLoadNotification = false
        private var timeoutTask: Task<Void, Never>?
        private var initialLoadFallbackTask: Task<Void, Never>?
        private var chapterBoundaryTask: Task<Void, Never>?
        private var panStartOffset: CGFloat?

        init(parent: EPUBWebView) { self.parent = parent }

        @objc func handleReaderPan(_ gesture: UIPanGestureRecognizer) {
            guard parent.pageLayout != .scroll, let scrollView = view?.scrollView else { return }
            switch gesture.state {
            case .began:
                chapterBoundaryTask?.cancel()
                panStartOffset = scrollView.contentOffset.x
            case .ended, .cancelled, .failed:
                let translation = gesture.translation(in: scrollView).x
                let velocity = gesture.velocity(in: scrollView).x
                let direction = abs(translation) > 24 ? (translation < 0 ? 1 : -1) : (velocity < 0 ? 1 : -1)
                let startOffset = panStartOffset ?? scrollView.contentOffset.x
                panStartOffset = nil
                guard direction != 0 else { return }
                chapterBoundaryTask?.cancel()
                chapterBoundaryTask = Task { @MainActor [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    var waitCount = 0
                    while scrollView.isDecelerating && waitCount < 30 && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        waitCount += 1
                    }
                    guard !Task.isCancelled else { return }
                    let pageWidth = max(scrollView.bounds.width, 1)
                    let maximumOffset = max(scrollView.contentSize.width - pageWidth, 0)
                    let finalOffset = scrollView.contentOffset.x
                    let atBoundary = direction > 0
                        ? startOffset >= maximumOffset - 2 && finalOffset >= maximumOffset - 2
                        : startOffset <= 2 && finalOffset <= 2
                    guard atBoundary else { return }
                    self.parent.onNavigate(self.parent.chapter + direction, nil)
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            activeNavigation = navigation
            let expectedPath = loadedPath
            pendingLoadNotification = false
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.activeNavigation === navigation, self.loadedPath == expectedPath else { return }
                webView.stopLoading()
                self.parent.onError("This chapter took too long to open. Try again or import another copy of the book.")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard activeNavigation === navigation else { return }
            timeoutTask?.cancel()
            isReady = true
            appearanceKey = ""
            pendingLoadNotification = true
            applyAppearance(restoring: restoreFraction, fragment: parent.targetFragment)
            let expectedPath = loadedPath
            initialLoadFallbackTask?.cancel()
            initialLoadFallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.loadedPath == expectedPath else { return }
                self.finishInitialLoadIfNeeded()
            }
        }

        func applyAppearance(restoring fraction: Double? = nil, fragment: String? = nil) {
            guard let view else { return }
            let foreground = Self.cssColor(parent.palette.foreground, view: view)
            let background = Self.cssColor(parent.palette.background, view: view)
            let family: String
            switch parent.font {
            case .systemSerif: family = "ui-serif, Georgia, serif"
            case .systemSans: family = "-apple-system, sans-serif"
            case .rounded: family = "ui-rounded, -apple-system, sans-serif"
            case .georgia: family = "Georgia, serif"
            case .palatino: family = "Palatino, serif"
            case .avenir: family = "'Avenir Next', sans-serif"
            case .monospaced: family = "ui-monospace, monospace"
            }
            let metrics = ReaderLayoutMetrics.resolve(viewport: parent.viewportSize, pageLayout: parent.pageLayout, font: parent.font, fontSize: parent.fontSize)
            let nativeFont = parent.font.uiFont(size: parent.fontSize)
            let lineHeight = (nativeFont.lineHeight + parent.fontSize * 0.26) / max(parent.fontSize, 1)
            let paragraphSpacing = parent.fontSize * 0.55
            let paged = parent.pageLayout != .scroll
            let columns = metrics.effectiveColumnCount
            let columnWidth = (max(parent.viewportSize.width, 1) - metrics.gutter * CGFloat(max(columns - 1, 0))) / CGFloat(columns)
            let css = """
            html { width:\(max(parent.viewportSize.width, 1))px!important; min-height:100%; background:\(background)!important; color:\(foreground)!important; -webkit-text-size-adjust:none; }
            body { color:\(foreground)!important; background:\(background)!important; font-family:\(family)!important; font-size:\(parent.fontSize)px!important; font-weight:400!important; line-height:\(lineHeight)!important; margin:0 auto!important; padding:0 \(metrics.horizontalMargin)px!important; box-sizing:border-box; overflow-wrap:anywhere; }
            html body * { color:inherit!important; font-family:inherit!important; font-size:inherit!important; font-weight:400!important; line-height:inherit!important; background-color:transparent!important; background-image:none!important; max-width:100%!important; box-sizing:border-box!important; }
            p, li, blockquote, dd { text-indent:0!important; margin-inline-start:0!important; margin-inline-end:0!important; }
            html body p { margin-block-start:0!important; margin-block-end:\(paragraphSpacing)px!important; }
            html body h1, html body h2, html body h3, html body h4, html body h5, html body h6, html body strong, html body b, html body th { font-weight:600!important; }
            html body h1 { font-size:1.7em!important; } html body h2 { font-size:1.45em!important; } html body h3 { font-size:1.25em!important; } html body h4, html body h5, html body h6 { font-size:1.1em!important; }
            img, svg, video, canvas, table { max-width:100%!important; height:auto; object-fit:contain; } pre, code { white-space:pre-wrap!important; overflow-wrap:anywhere!important; } a { text-decoration:underline; }
            [style*="width"], [width] { max-width:100%!important; }
            :root { --cloudreader-chrome-visible:\(parent.isChromeVisible ? 1 : 0); }
            \(paged ? "html { height:100%!important; overflow-x:auto!important; overflow-y:hidden!important; } body { height:100vh!important; width:\(max(parent.viewportSize.width, 1))px!important; padding:0!important; overflow:visible!important; column-count:auto!important; column-width:\(columnWidth)px!important; column-gap:\(metrics.gutter)px!important; column-fill:auto!important; break-inside:auto; } html body > :not(img):not(svg):not(video):not(canvas) { margin-inline:\(metrics.horizontalMargin)px!important; }" : "body { width:auto!important; max-width:\(metrics.maximumProseWidth + metrics.horizontalMargin * 2)px!important; margin:0 auto!important; }")
            """
            let key = "\(css)|height:\(parent.viewportSize.height)"
            guard appearanceKey != key || fraction != nil else { return }
            appearanceKey = key
            let arguments: [String: Any] = [
                "css": css, "paged": paged,
                "fraction": fraction as Any? ?? NSNull(),
                "fragment": fragment as Any? ?? NSNull(), "chromeVisible": parent.isChromeVisible,
                "viewportWidth": max(parent.viewportSize.width, 1), "columns": columns, "gutter": metrics.gutter
            ]
            let expectedPath = loadedPath
            let identifier = UUID()
            configurationID = identifier
            view.callAsyncJavaScript("return await window.cloudReader.configure(css, paged, fraction, fragment, chromeVisible, viewportWidth, columns, gutter);", arguments: arguments, in: nil, in: .defaultClient, completionHandler: { [weak self] result in
                guard let self, self.isReady, self.loadedPath == expectedPath, self.configurationID == identifier else { return }
                switch result {
                case .success:
                    self.finishInitialLoadIfNeeded()
                case .failure(let error):
                    if (error as NSError).code != NSURLErrorCancelled { self.parent.onError(error.localizedDescription) }
                }
            })
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isReady, message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
            if let fraction = payload["progress"] as? Double, fraction.isFinite { parent.onProgress(min(max(fraction, 0), 1)) }
            if payload["kind"] as? String == "location" {
                // Release the chapter overlay before publishing the first
                // visible page state. The shell can expose page controls as
                // soon as it receives that state, so the order matters: a
                // test or user must never see a ready page indicator while
                // the loading overlay still blocks the web view underneath.
                finishInitialLoadIfNeeded()
                parent.onNavigationState(payload["page"] as? Int, payload["pages"] as? Int, (payload["progress"] as? Double) ?? 0)
            }
            if payload["kind"] as? String == "boundary", let direction = payload["direction"] as? Int {
                parent.onNavigate(parent.chapter + (direction > 0 ? 1 : -1), nil)
            }
            if let selection = payload["selection"] as? String { parent.onSelection(String(selection.prefix(18_000))) }
            if payload["kind"] as? String == "tap" { parent.onContentTap() }
        }

        private func finishInitialLoadIfNeeded() {
            guard pendingLoadNotification else { return }
            pendingLoadNotification = false
            initialLoadFallbackTask?.cancel()
            initialLoadFallbackTask = nil
            parent.onLoaded()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  url.scheme == "cloudreader-epub", url.host == "book" else { decisionHandler(.cancel); return }
            let path = String(url.path.dropFirst())
            if navigationAction.navigationType == .linkActivated, path != loadedPath {
                decisionHandler(.cancel)
                let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
                let destination = EPUBNavigationPolicy.destination(
                    path: path,
                    fragment: fragment,
                    currentPath: loadedPath,
                    chapters: parent.publication.chapters,
                    mediaTypes: parent.publication.mediaTypes
                )
                if let destination {
                    switch destination {
                    case let .chapter(index, targetFragment):
                        parent.onNavigate(index, targetFragment)
                    case .document:
                        let root = parent.publication.rootURL.standardizedFileURL
                        let resource = root.appendingPathComponent(path).standardizedFileURL
                        if resource.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: resource.path) {
                            parent.onOpenNote?(path, fragment)
                        }
                    }
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
            if (error as NSError).code != NSURLErrorCancelled { parent.onError(error.localizedDescription) }
        }

        private static func cssColor(_ color: UIColor, view: UIView) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: view.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
            return "rgb(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)))"
        }

        deinit {
            timeoutTask?.cancel()
            initialLoadFallbackTask?.cancel()
            chapterBoundaryTask?.cancel()
        }
    }

    private static let viewportScript = """
    (() => {
      let meta = document.querySelector('meta[name="viewport"]');
      if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; (document.head || document.documentElement).appendChild(meta); }
      meta.content = 'width=device-width, initial-scale=1';
    })();
    """

    private static let readerScript = """
    (() => {
      let paged = false, restoring = true, configured = false, timer, previous = 0, pageWidth = 1, pageGap = 0, pagesPerView = 1, suppressScrollUntil = 0, cachedPageCount = null;
      let desired = null, restoreVersion = 0, passage = null;
      const waiters = [];
      let pointerStart = null;
      const root = () => document.scrollingElement || document.documentElement;
      const distance = () => {
        const e = root();
        return Math.max(0, paged ? e.scrollWidth - innerWidth : e.scrollHeight - innerHeight);
      };
      const position = () => {
        const extent = distance();
        return extent > 1 ? Math.max(0, Math.min(1, (paged ? scrollX : scrollY) / extent)) : 0;
      };
      const restore = fraction => {
        const extent = distance();
        scrollTo(paged ? Math.round(fraction * extent / Math.max(pageWidth, 1)) * pageWidth : 0, paged ? 0 : fraction * extent);
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
            if (occurrence++ === targetOccurrence) { const range = document.createRange(); range.setStart(node, offset); range.setEnd(node, offset + Math.min(quote.length, 24)); return range; }
          }
        }
        return null;
      };
      const capturePassage = () => {
        const hit = document.elementFromPoint(Math.min(36, innerWidth - 1), Math.min(36, innerHeight - 1));
        const container = hit || document.body;
        const localWalker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
        let targetNode = null, quote = '';
        while (localWalker.nextNode()) { const value = localWalker.currentNode.nodeValue.trim(); if (value.length > 24) { targetNode = localWalker.currentNode; quote = value.slice(0, 56); break; } }
        if (targetNode) {
          const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
          let occurrence = 0;
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (node === targetNode) break;
            let offset = -1;
            while ((offset = node.nodeValue.indexOf(quote, offset + 1)) >= 0) occurrence++;
          }
          const range = document.createRange(); range.selectNodeContents(targetNode);
          const rects = range.getClientRects(), rect = rects.length ? rects[0] : null;
          return {text:quote, occurrence, x:rect ? rect.left : 36, y:rect ? rect.top : 36};
        }
        return passage;
      };
      const requestRestore = (fraction, fragment, passageAnchor = null) => {
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
          const anchor = request.fragment === null ? null : document.getElementById(request.fragment) || document.getElementsByName(request.fragment)[0];
          const passageRange = anchor ? null : findPassage(request.passageAnchor);
          if (anchor) anchor.scrollIntoView({block:'start', inline:'start'});
          else if (passageRange) {
            const rect = passageRange.getBoundingClientRect();
            if (paged) scrollTo(Math.floor((scrollX + rect.left) / Math.max(pageWidth, 1)) * pageWidth, 0);
            else scrollTo(0, Math.max(0, scrollY + rect.top - request.passageAnchor.y));
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
        const e = root(), extent = distance(), progress = position();
        let page = paged ? Math.max(1, Math.floor(scrollX / Math.max(pageWidth, 1)) * pagesPerView + 1) : Math.max(0, Math.floor(scrollY / Math.max(innerHeight, 1)));
        if (cachedPageCount === null) {
          if (!paged) cachedPageCount = Math.max(1, Math.ceil((e.scrollHeight + 1) / Math.max(innerHeight, 1)));
          else {
            const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
            let lastRect = null;
            while (walker.nextNode()) {
              if (!walker.currentNode.nodeValue.trim()) continue;
              const range = document.createRange(); range.selectNodeContents(walker.currentNode);
              const rects = range.getClientRects();
              if (rects.length) lastRect = rects[rects.length - 1];
            }
            if (!lastRect) cachedPageCount = 1;
            else {
              const pageWidthInner = (pageWidth - pageGap * (pagesPerView - 1)) / pagesPerView;
              const documentRight = Math.max(0, lastRect.right + scrollX - 1);
              const spread = Math.floor(documentRight / pageWidth);
              const withinSpread = documentRight - spread * pageWidth;
              const pagesInLastSpread = pagesPerView === 1 || withinSpread <= pageWidthInner ? 1 : 2;
              cachedPageCount = spread * pagesPerView + pagesInLastSpread;
            }
          }
        }
        const pages = cachedPageCount;
        if (paged) page = Math.min(page, Math.floor((pages - 1) / pagesPerView) * pagesPerView + 1);
        else page = Math.min(page, pages - 1);
        webkit.messageHandlers.reader.postMessage({kind:'location', progress, page, pages});
      };
      window.cloudReader = { configure(css, horizontal, fraction, fragment, chromeVisible, measuredWidth, columnCount, measuredGap) {
        const target = fraction === null ? (desired ? desired.fraction : position()) : fraction;
        const keepPassage = fraction === null && fragment === null ? capturePassage() : null;
        paged = horizontal;
        pageWidth = Math.max(measuredWidth || innerWidth, 1);
        pageGap = measuredGap || 0;
        pagesPerView = Math.max(columnCount || 1, 1);
        cachedPageCount = null;
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
        style.textContent = css;
        configured = true;
        const ready = new Promise(resolve => waiters.push(resolve));
        requestRestore(target, fragment, keepPassage);
        return ready;
      }};
      addEventListener('scroll', () => {
        if (restoring || Date.now() < suppressScrollUntil) return;
        previous = position();
        clearTimeout(timer);
        timer = setTimeout(() => { if (!restoring) { webkit.messageHandlers.reader.postMessage({progress:position()}); report(); } }, 100);
      }, {passive:true});
      document.addEventListener('selectionchange', () => webkit.messageHandlers.reader.postMessage({selection:String(getSelection())}));
      document.addEventListener('pointerup', event => {
        if (pointerStart && (Math.abs(event.clientX - pointerStart.x) > 8 || Math.abs(event.clientY - pointerStart.y) > 8)) { pointerStart = null; return; }
        pointerStart = null;
        if (String(getSelection()).trim()) return;
        const target = event.target;
        if (target && target.closest && target.closest('a,button,input,select,textarea,video,audio,[contenteditable=true]')) return;
        webkit.messageHandlers.reader.postMessage({kind:'tap'});
      }, {passive:true});
      document.addEventListener('pointerdown', event => {
        pointerStart = {x:event.clientX, y:event.clientY};
      }, {passive:true});
    })();
    """
}

private final class EPUBResourceHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let mediaTypes: [String: String]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(root: URL, mediaTypes: [String: String]) { self.root = root; self.mediaTypes = mediaTypes }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url, requestURL.host == "book" else {
            urlSchemeTask.didFailWithError(EPUBError.unsafePath); return
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
                } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self, self.tasks.removeValue(forKey: id) != nil else { return }
            switch result {
            case .success(let (data, mime)):
                urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime == "text/html" ? "utf-8" : nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error): urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
