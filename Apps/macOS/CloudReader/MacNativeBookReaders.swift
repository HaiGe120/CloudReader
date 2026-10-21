import AppKit
import CloudReaderCore
import PDFKit
import SwiftUI

enum MacTextSourceAnchoring {
    static func sourceOffset(ofPageAt pageIndex: Int, pages: [String], source: String) -> Int? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let source = source as NSString
        var searchLocation = 0
        for (index, page) in pages.enumerated() {
            guard searchLocation <= source.length else { return nil }
            let found = source.range(of: page, options: [], range: NSRange(location: searchLocation, length: source.length - searchLocation))
            guard found.location != NSNotFound else { continue }
            if index == pageIndex { return found.location }
            searchLocation = NSMaxRange(found)
        }
        return nil
    }

    static func pageIndex(containing offset: Int, pages: [String], source: String) -> Int? {
        let source = source as NSString
        var searchLocation = 0
        for (index, page) in pages.enumerated() {
            guard searchLocation <= source.length else { return nil }
            let found = source.range(of: page, options: [], range: NSRange(location: searchLocation, length: source.length - searchLocation))
            guard found.location != NSNotFound else { continue }
            if NSLocationInRange(offset, found) || offset == NSMaxRange(found) { return index }
            searchLocation = NSMaxRange(found)
        }
        return nil
    }
}

enum MacNativeClickFilter {
    static func shouldToggleChrome(clickCount: Int, dragged: Bool, hasModifiers: Bool, selectionChanged: Bool) -> Bool {
        clickCount == 1 && !dragged && !hasModifiers && !selectionChanged
    }
}

private struct MacTextContentClickMonitor: NSViewRepresentable {
    let onTap: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onTap = onTap
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.onTap = onTap }

    final class MonitorView: NSView {
        var onTap: (() -> Void)?
        private var monitors: [Any] = []
        private var pending: DispatchWorkItem?
        private var downPoint: NSPoint?
        private var downSelection: (range: NSRange, text: String)?
        private weak var downTextView: NSTextView?
        private var downHadModifiers = false
        private var didDrag = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitors()
            guard let window else { return }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self, weak window] event in
                guard let self, let window, event.window === window else { return event }
                self.pending?.cancel()
                self.pending = nil
                self.downPoint = nil
                guard self.containsContentPoint(event), !self.isInteractiveControl(at: event) else { return event }
                self.downPoint = event.locationInWindow
                self.didDrag = false
                self.downTextView = event.clickCount == 1 ? self.textView(at: event) : nil
                self.downSelection = self.downTextView.map { ($0.selectedRange(), $0.string) }
                self.downHadModifiers = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                return event
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .scrollWheel, .magnify], handler: { [weak self, weak window] event in
                guard let self, let window, event.window === window else { return event }
                self.pending?.cancel()
                self.pending = nil
                self.didDrag = true
                return event
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self, weak window] event in
                guard let self, let window, event.window === window else { return event }
                self.finishClick(event)
                return event
            }) { monitors.append(monitor) }
        }

        deinit { removeMonitors() }

        private func finishClick(_ event: NSEvent) {
            guard let start = downPoint, containsContentPoint(event), !isInteractiveControl(at: event) else { return }
            let textView = downTextView
            let before = downSelection
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            let dragged = didDrag || hypot(dx, dy) > 3
            let hasModifiers = downHadModifiers || !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self else { return }
                let changed: Bool
                if let textView, let before {
                    let after = textView.selectedRange()
                    changed = textView.string != before.text ||
                        (after != before.range && (after.length > 0 || before.range.length > 0))
                } else { changed = false }
                guard MacNativeClickFilter.shouldToggleChrome(
                    clickCount: event.clickCount,
                    dragged: dragged,
                    hasModifiers: hasModifiers,
                    selectionChanged: changed
                ) else { return }
                self.onTap?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            downPoint = nil
            downSelection = nil
            downTextView = nil
        }

        private func containsContentPoint(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func isInteractiveControl(at event: NSEvent) -> Bool {
            guard let root = event.window?.contentView else { return true }
            var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
            while let view = hit, view !== root {
                if view is NSButton || view is NSSlider || view is NSScroller { return true }
                if let text = view as? NSTextView, text.isEditable { return true }
                hit = view.superview
            }
            return false
        }

        private func textView(at event: NSEvent) -> NSTextView? {
            guard let root = event.window?.contentView else { return nil }
            let point = root.convert(event.locationInWindow, from: nil)
            var view = root.hitTest(point)
            while let current = view {
                if let textView = current as? NSTextView { return textView }
                view = current.superview
            }
            return nil
        }

        private func removeMonitors() {
            pending?.cancel()
            pending = nil
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
    }
}

struct MacTextReaderView: View {
    let book: Book
    let progress: Double
    let pageLayoutRaw: String
    let font: Font
    let platformFont: NSFont
    let fontIdentifier: String
    let fontSize: Double
    let backgroundColor: Color
    let foregroundColor: Color
    let onProgressChanged: (Double) -> Void
    let onSelectionChanged: (String) -> Void
    let isChromeVisible: Bool
    let navigationRequest: ReaderNavigationRequest?
    let onNavigationStateChanged: (ReaderNavigationState) -> Void
    let onContentTap: () -> Void

    @State private var fullText: String
    @State private var paragraphs: [String]
    @State private var contentHash: Int
    @State private var pageGroupIndex = 0
    @State private var scrollGroupIndex: Int?
    @State private var paginationCacheSignature = ""
    @State private var paginationCache: [String] = []
    @State private var navigationRequestID: UUID?
    @State private var sourceAnchorOffset: Int?

    init(
        book: Book,
        text: String,
        progress: Double,
        pageLayoutRaw: String,
        font: Font,
        platformFont: NSFont,
        fontIdentifier: String,
        fontSize: Double,
        backgroundColor: Color,
        foregroundColor: Color,
        onProgressChanged: @escaping (Double) -> Void,
        onSelectionChanged: @escaping (String) -> Void,
        isChromeVisible: Bool = true,
        navigationRequest: ReaderNavigationRequest? = nil,
        onNavigationStateChanged: @escaping (ReaderNavigationState) -> Void = { _ in },
        onContentTap: @escaping () -> Void = {}
    ) {
        self.book = book
        self.progress = progress
        self.pageLayoutRaw = pageLayoutRaw
        self.font = font
        self.platformFont = platformFont
        self.fontIdentifier = fontIdentifier
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.onProgressChanged = onProgressChanged
        self.onSelectionChanged = onSelectionChanged
        self.isChromeVisible = isChromeVisible
        self.navigationRequest = navigationRequest
        self.onNavigationStateChanged = onNavigationStateChanged
        self.onContentTap = onContentTap

        let content = "\(book.title)\n\n\(text)"
        _fullText = State(initialValue: content)
        _paragraphs = State(initialValue: content.components(separatedBy: "\n"))
        _contentHash = State(initialValue: content.hashValue)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
            let metrics = ReaderLayoutMetrics.resolve(
                viewport: geometry.size,
                pageLayout: layout,
                font: ReaderFont(rawValue: fontIdentifier) ?? .systemSerif,
                fontSize: fontSize
            )
            let pagesPerGroup = metrics.effectiveColumnCount
            let pageWidth = pagesPerGroup == 2
                ? max((geometry.size.width - metrics.horizontalMargin * 2 - metrics.gutter) / 2, 280)
                : max(min(geometry.size.width - metrics.horizontalMargin * 2, metrics.maximumProseWidth), 1)
            let pageHeight = max(geometry.size.height - 48, 320)
            let paginationSignature = "\(book.id.uuidString)|\(contentHash)|\(layout.rawValue)|\(Int(pageWidth.rounded()))|\(Int(pageHeight.rounded()))|\(fontIdentifier)|\(fontSize)"
            let pageTexts = paginationCacheSignature == paginationSignature ? paginationCache : []
            let groupCount = ReaderPaginationPolicy.pageGroupCount(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            let safeGroupIndex = min(max(pageGroupIndex, 0), groupCount - 1)
            let firstPageIndex = safeGroupIndex * pagesPerGroup
            let visiblePageTexts = layout == .scroll ? paragraphs : Array(pageTexts[firstPageIndex..<min(firstPageIndex + pagesPerGroup, pageTexts.count)])

            Group {
                if layout == .scroll {
                    scrollingReader(horizontalMargin: metrics.horizontalMargin, maximumWidth: metrics.maximumProseWidth)
                } else if pageTexts.isEmpty {
                    ProgressView("Preparing pages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pagedReader(
                        pages: pageTexts,
                        pageWidth: pageWidth,
                        pageHeight: pageHeight,
                        viewportWidth: geometry.size.width,
                        pagesPerGroup: pagesPerGroup,
                        groupCount: groupCount
                    )
                }
            }
            .onAppear {
                if layout != .scroll, !pageTexts.isEmpty {
                    restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
                }
            }
            .task(id: paginationSignature) {
                guard layout != .scroll else { return }
                paginationCache = []
                paginationCacheSignature = ""
                let source = fullText
                let font = platformFont
                let width = pageWidth - 40
                let height = pageHeight - 40
                let pages = await Task.detached(priority: .userInitiated) {
                    MacReaderTextPagination.pages(from: source, width: width, height: height, font: font)
                }.value
                guard !Task.isCancelled else { return }
                paginationCache = pages
                paginationCacheSignature = paginationSignature
                restorePage(pageTexts: pages, pagesPerGroup: pagesPerGroup)
                let loadedGroupCount = ReaderPaginationPolicy.pageGroupCount(pageCount: pages.count, pagesPerGroup: pagesPerGroup)
                publishNavigationState(pageTexts: pages, pagesPerGroup: pagesPerGroup, groupCount: loadedGroupCount)
            }
            .onChange(of: progress) {
                if layout != .scroll {
                    restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
                }
            }
            .onChange(of: pageTexts.count) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: pageLayoutRaw) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: pagesPerGroup) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: geometry.size) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: fontIdentifier) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: fontSize) {
                restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: isChromeVisible) {
                if layout != .scroll { restorePage(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup) }
            }
            .onAppear {
                if layout == .scroll {
                    onNavigationStateChanged(ReaderNavigationState(progress: progress, canNavigatePrevious: progress > 0, canNavigateNext: progress < 1))
                } else if !pageTexts.isEmpty {
                    publishNavigationState(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup, groupCount: groupCount)
                }
            }
            .onChange(of: navigationRequest) { _, request in
                guard let request, request.id != navigationRequestID else { return }
                navigationRequestID = request.id
                apply(request.command, groupCount: groupCount)
            }
            .onChange(of: scrollGroupIndex) { _, newIndex in
                guard layout != .scroll,
                      let newIndex else { return }
                let boundedIndex = min(max(newIndex, 0), groupCount - 1)
                if pageGroupIndex != boundedIndex {
                    pageGroupIndex = boundedIndex
                }
            }
            .onChange(of: pageGroupIndex) {
                guard layout != .scroll else { return }
                let boundedIndex = min(max(pageGroupIndex, 0), groupCount - 1)
                if scrollGroupIndex != boundedIndex {
                    scrollGroupIndex = boundedIndex
                }
                if pageTexts.indices.contains(boundedIndex * pagesPerGroup) {
                    sourceAnchorOffset = sourceOffset(for: boundedIndex * pagesPerGroup, pages: pageTexts)
                }
                onProgressChanged(
                    ReaderPaginationPolicy.progress(
                        pageGroupIndex: pageGroupIndex,
                        pageCount: pageTexts.count,
                        pagesPerGroup: pagesPerGroup
                    )
                )
                publishNavigationState(pageTexts: pageTexts, pagesPerGroup: pagesPerGroup, groupCount: groupCount)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
                guard let textView = notification.object as? NSTextView,
                      textView.window?.firstResponder === textView,
                      visiblePageTexts.contains(textView.string) else { return }
                let range = textView.selectedRange()
                guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else {
                    onSelectionChanged("")
                    return
                }
                let passage = (textView.string as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onSelectionChanged(passage)
            }
        }
        .background(backgroundColor)
        .background(MacTextContentClickMonitor(onTap: onContentTap))
    }

    private func scrollingReader(horizontalMargin: CGFloat, maximumWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        let paragraph = paragraphs[index]
                        Text(paragraph.isEmpty ? " " : paragraph)
                            .font(font)
                            .lineSpacing(5)
                            .foregroundStyle(foregroundColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .frame(maxWidth: maximumWidth)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .padding(.horizontal, horizontalMargin)
                .frame(maxWidth: .infinity)
            }
            .background(backgroundColor)
            .onAppear {
                let index = Int((book.progress * Double(max(paragraphs.count - 1, 0))).rounded())
                proxy.scrollTo(index, anchor: .top)
            }
            .onScrollGeometryChange(for: Int.self) { geometry in
                let range = geometry.contentSize.height - geometry.containerSize.height
                guard range > 0 else { return 0 }
                return Int((min(max(geometry.contentOffset.y / range, 0), 1) * 100).rounded())
            } action: { _, progress in
                onProgressChanged(Double(progress) / 100)
                onNavigationStateChanged(ReaderNavigationState(
                    progress: Double(progress) / 100,
                    canNavigatePrevious: progress > 0,
                    canNavigateNext: progress < 100
                ))
            }
        }
    }

    private func pagedReader(
        pages: [String],
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        viewportWidth: CGFloat,
        pagesPerGroup: Int,
        groupCount: Int
    ) -> some View {
        return ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<groupCount, id: \.self) { groupIndex in
                        let firstIndex = groupIndex * pagesPerGroup
                        HStack(spacing: ReaderLayoutMetrics.spreadGutter) {
                            pageColumn(pages[firstIndex], width: pageWidth, height: pageHeight)
                            if pagesPerGroup == 2 {
                                if firstIndex + 1 < pages.count {
                                    pageColumn(pages[firstIndex + 1], width: pageWidth, height: pageHeight)
                                } else {
                                    Color.clear.frame(width: pageWidth, height: pageHeight)
                                }
                            }
                        }
                        .frame(width: viewportWidth, height: pageHeight)
                        .id(groupIndex)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollGroupIndex, anchor: .center)
            .background(backgroundColor)

        }
    }

    private func pageColumn(_ text: String, width: CGFloat, height: CGFloat) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(font)
            .lineSpacing(5)
            .foregroundStyle(foregroundColor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(backgroundColor)
    }

    private func restorePage(pageTexts: [String], pagesPerGroup: Int) {
        guard !pageTexts.isEmpty else { return }
        let restoredIndex: Int
        if let sourceAnchorOffset,
           let pageIndex = MacTextSourceAnchoring.pageIndex(containing: sourceAnchorOffset, pages: pageTexts, source: fullText) {
            restoredIndex = pageIndex / max(pagesPerGroup, 1)
        } else {
            restoredIndex = ReaderPaginationPolicy.pageGroupIndex(
                progress: progress,
                pageCount: pageTexts.count,
                pagesPerGroup: pagesPerGroup
            )
        }
        pageGroupIndex = restoredIndex
        scrollGroupIndex = restoredIndex
        sourceAnchorOffset = sourceOffset(for: restoredIndex * pagesPerGroup, pages: pageTexts)
    }

    private func sourceOffset(for pageIndex: Int, pages: [String]) -> Int? {
        MacTextSourceAnchoring.sourceOffset(ofPageAt: pageIndex, pages: pages, source: fullText)
    }

    private func publishNavigationState(pageTexts: [String], pagesPerGroup: Int, groupCount: Int) {
        guard !pageTexts.isEmpty else { return }
        let group = min(max(pageGroupIndex, 0), max(groupCount - 1, 0))
        let first = group * pagesPerGroup
        let end = min(first + pagesPerGroup, pageTexts.count)
        onNavigationStateChanged(ReaderNavigationState(
            progress: groupCount > 1 ? Double(group) / Double(groupCount - 1) : 0,
            pageRange: (first + 1)...max(first + 1, end),
            pageCount: pageTexts.count,
            canNavigatePrevious: group > 0,
            canNavigateNext: group < groupCount - 1
        ))
    }

    private func apply(_ command: ReaderNavigationCommand, groupCount: Int) {
        switch command {
        case .previous: pageGroupIndex = max(pageGroupIndex - 1, 0)
        case .next: pageGroupIndex = min(pageGroupIndex + 1, groupCount - 1)
        case .seek(let progress): pageGroupIndex = min(max(Int(progress * Double(max(groupCount - 1, 0)).rounded()), 0), groupCount - 1)
        case .previousChapter, .nextChapter, .chapter: break
        }
    }
}

private enum MacReaderTextPagination {
    static func pages(from text: String, width: CGFloat, height: CGFloat, font: NSFont) -> [String] {
        let safeWidth = max(width, 40)
        let safeHeight = max(height, font.ascender - font.descender)
        return ReaderPaginationPolicy.pages(from: text, fits: { candidate in
            measuredHeight(of: candidate, width: safeWidth, font: font) <= safeHeight
        })
    }

    static func measuredHeight(of text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph],
            context: nil
        )
        return ceil(rect.height)
    }

}

struct MacPDFLayoutSnapshot {
    let pageIndex: Int?
    let zoomScale: CGFloat

    init(pageIndex: Int?, zoomScale: CGFloat) {
        self.pageIndex = pageIndex
        self.zoomScale = zoomScale
    }

    init(view: PDFView) {
        pageIndex = view.currentPage.flatMap { page in
            view.document.map { $0.index(for: page) }
        }
        zoomScale = view.scaleFactor
    }

    func restoredPageIndex(pageCount: Int) -> Int? {
        guard pageCount > 0, let pageIndex else { return nil }
        return min(max(pageIndex, 0), pageCount - 1)
    }

    var restoredZoomScale: CGFloat? {
        zoomScale.isFinite && zoomScale > 0 ? zoomScale : nil
    }
}

struct MacPDFReaderView: NSViewRepresentable {
    let url: URL
    let progress: Double
    let pageLayoutRaw: String
    let availableWidth: CGFloat
    let backgroundColor: Color
    let onProgressChanged: (Double) -> Void
    let onSelectionChanged: (String) -> Void
    let isChromeVisible: Bool
    let navigationRequest: ReaderNavigationRequest?
    let onNavigationStateChanged: (ReaderNavigationState) -> Void
    let onContentTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onSelectionChanged: onSelectionChanged, onNavigationStateChanged: onNavigationStateChanged)
    }

    func makeNSView(context: Context) -> MacNavigablePDFView {
        let view = MacNavigablePDFView()
        view.onCleanContentClick = onContentTap
        view.autoScales = true
        view.backgroundColor = NSColor(backgroundColor)
        view.pageShadowsEnabled = false
        view.displaysPageBreaks = false
        view.document = PDFDocument(url: url)
        configureLayout(of: view, preservingPage: false)
        context.coordinator.layoutKey = layoutKey
        context.coordinator.observeChanges(in: view)
        showSavedPage(in: view)
        context.coordinator.emitState(in: view)
        return view
    }

    func updateNSView(_ view: MacNavigablePDFView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onNavigationStateChanged = onNavigationStateChanged
        view.onCleanContentClick = onContentTap
        view.backgroundColor = NSColor(backgroundColor)
        view.pageShadowsEnabled = false
        view.displaysPageBreaks = false
        if view.document?.documentURL?.standardizedFileURL != url.standardizedFileURL {
            view.document = PDFDocument(url: url)
            configureLayout(of: view, preservingPage: false)
            showSavedPage(in: view)
        } else if context.coordinator.layoutKey != layoutKey {
            configureLayout(of: view, preservingPage: true)
        }
        context.coordinator.layoutKey = layoutKey
        if let navigationRequest { context.coordinator.apply(navigationRequest, in: view) }
        context.coordinator.emitState(in: view)
    }

    private func configureLayout(of view: PDFView, preservingPage: Bool) {
        let document = view.document
        let snapshot = preservingPage ? MacPDFLayoutSnapshot(view: view) : nil
        let oldDestination = preservingPage ? view.currentDestination : nil
        let oldSelection = preservingPage ? view.currentSelection?.copy() as? PDFSelection : nil
        let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
        let useFacingPages = layout == .facingPages && availableWidth >= ReaderLayoutMetrics.spreadBreakpoint
        (view as? MacNavigablePDFView)?.arrowPageStep = useFacingPages ? 2 : 1
        let displayMode: PDFDisplayMode
        let direction: PDFDisplayDirection
        switch layout {
        case .scroll, .singlePage:
            displayMode = .singlePageContinuous
            direction = .vertical
        case .facingPages where useFacingPages:
            displayMode = .twoUp
            direction = .horizontal
        case .facingPages:
            displayMode = .singlePageContinuous
            direction = .vertical
        }
        if view.displayMode != displayMode || view.displayDirection != direction {
            view.displayMode = displayMode
            view.displayDirection = direction
        }
        if let snapshot, let nativeView = view as? MacNavigablePDFView {
            nativeView.restoreAfterLayout(destination: oldDestination,
                pageIndex: snapshot.restoredPageIndex(pageCount: document?.pageCount ?? 0),
                zoom: snapshot.restoredZoomScale ?? view.scaleFactor, selection: oldSelection)
            return
        }
        if let zoom = snapshot?.restoredZoomScale { view.scaleFactor = zoom }
        if let oldDestination {
            view.go(to: oldDestination)
        } else if let snapshot,
                  let pageIndex = snapshot.restoredPageIndex(pageCount: document?.pageCount ?? 0),
                  let page = document?.page(at: pageIndex) {
            view.go(to: page)
        }
        if let oldSelection { view.setCurrentSelection(oldSelection, animate: false) }
    }

    private var layoutKey: String {
        "\(pageLayoutRaw):\(Int(availableWidth.rounded())):\(isChromeVisible)"
    }

    private func showSavedPage(in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let pageIndex = min(max(Int((progress * Double(document.pageCount - 1)).rounded()), 0), document.pageCount - 1)
        if let page = document.page(at: pageIndex) { view.go(to: page) }
    }

    final class Coordinator {
        var onProgressChanged: (Double) -> Void
        var onSelectionChanged: (String) -> Void
        var onNavigationStateChanged: (ReaderNavigationState) -> Void
        private var observers: [NSObjectProtocol] = []
        private var lastNavigationRequestID: UUID?
        private var stateEmissionID = UUID()
        var layoutKey = ""

        init(onProgressChanged: @escaping (Double) -> Void, onSelectionChanged: @escaping (String) -> Void, onNavigationStateChanged: @escaping (ReaderNavigationState) -> Void) {
            self.onProgressChanged = onProgressChanged
            self.onSelectionChanged = onSelectionChanged
            self.onNavigationStateChanged = onNavigationStateChanged
        }

        func apply(_ request: ReaderNavigationRequest, in view: PDFView) {
            guard lastNavigationRequestID != request.id, let document = view.document, document.pageCount > 0 else { return }
            lastNavigationRequestID = request.id
            (view as? MacNavigablePDFView)?.cancelPendingViewportRestore()
            let current = view.currentPage.map { document.index(for: $0) } ?? 0
            let target: Int
            switch request.command {
            case .previous: target = current - 1
            case .next: target = current + 1
            case .seek(let value): target = Int((value * Double(document.pageCount - 1)).rounded())
            case .previousChapter, .nextChapter, .chapter: return
            }
            let step = max((view as? MacNavigablePDFView)?.arrowPageStep ?? 1, 1)
            let steppedTarget: Int
            switch request.command {
            case .previous: steppedTarget = current - step
            case .next: steppedTarget = current + step
            default: steppedTarget = target
            }
            if let page = document.page(at: min(max(steppedTarget, 0), document.pageCount - 1)) { view.go(to: page) }
        }

        func emitState(in view: PDFView) {
            let identifier = UUID()
            stateEmissionID = identifier
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.stateEmissionID == identifier else { return }
                self.publishState(in: view)
            }
        }

        private func publishState(in view: PDFView) {
            guard let document = view.document, document.pageCount > 0,
                  let page = view.currentPage else { return }
            let index = document.index(for: page)
            let step = max((view as? MacNavigablePDFView)?.arrowPageStep ?? 1, 1)
            let first = index / step * step
            let last = min(first + step, document.pageCount)
            let denominator = max(document.pageCount - 1, 1)
            onNavigationStateChanged(ReaderNavigationState(
                progress: Double(index) / Double(denominator),
                pageRange: (first + 1)...max(first + 1, last),
                pageCount: document.pageCount,
                canNavigatePrevious: first > 0,
                canNavigateNext: last < document.pageCount
            ))
        }

        func observeChanges(in view: PDFView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak view, weak self] _ in
                guard let view,
                      let self,
                      let document = view.document,
                      let page = view.currentPage,
                      document.pageCount > 0 else { return }
                let index = document.index(for: page)
                self.onProgressChanged(Double(index) / Double(max(document.pageCount - 1, 1)))
                self.emitState(in: view)
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: view,
                queue: .main
            ) { [weak view, weak self] _ in
                guard let view, let self else { return }
                let passage = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async { [weak self] in self?.onSelectionChanged(passage) }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

final class MacNavigablePDFView: PDFView {
    var arrowPageStep = 1
    var onCleanContentClick: (() -> Void)?
    private var restoringViewport = false
    private var viewportRestoreID = UUID()
    private struct ViewportSnapshot {
        let document: PDFDocument
        let destination: PDFDestination?
        let pageIndex: Int?
        let zoom: CGFloat
        let selection: PDFSelection?
    }
    private var pendingViewport: ViewportSnapshot?

    override func setFrameSize(_ newSize: NSSize) {
        guard !restoringViewport, bounds.width > 0, bounds.height > 0,
              bounds.size != newSize, document != nil else {
            super.setFrameSize(newSize)
            return
        }
        let destination = currentDestination
        let selection = currentSelection?.copy() as? PDFSelection
        let zoom = scaleFactor
        super.setFrameSize(newSize)
        restoreAfterLayout(destination: destination, pageIndex: nil, zoom: zoom, selection: selection)
    }

    func restoreAfterLayout(destination: PDFDestination?, pageIndex: Int?, zoom: CGFloat, selection: PDFSelection?) {
        guard let document else { return }
        if pendingViewport == nil {
            pendingViewport = ViewportSnapshot(document: document, destination: destination,
                pageIndex: pageIndex, zoom: zoom, selection: selection)
        }
        let identifier = UUID()
        viewportRestoreID = identifier
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewportRestoreID == identifier, let snapshot = self.pendingViewport else { return }
            self.pendingViewport = nil
            guard self.document === snapshot.document else { return }
            self.restoringViewport = true
            self.autoScales = false
            if snapshot.zoom.isFinite, snapshot.zoom > 0 { self.scaleFactor = snapshot.zoom }
            if let destination = snapshot.destination { self.go(to: destination) }
            else if let index = snapshot.pageIndex, let page = self.document?.page(at: index) { self.go(to: page) }
            if let selection = snapshot.selection { self.setCurrentSelection(selection, animate: false) }
            self.restoringViewport = false
        }
    }

    func cancelPendingViewportRestore() {
        viewportRestoreID = UUID()
        pendingViewport = nil
    }
    private var mouseDownPoint: NSPoint?
    private var mouseDownPageIndex: Int?
    private var mouseDownSelection: String?
    private var didDrag = false
    private var pendingTap: DispatchWorkItem?
        private var downHadModifiers = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        cancelPendingViewportRestore()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }

        let direction: Int
        switch event.keyCode {
        case 123: direction = -1
        case 124: direction = 1
        default:
            super.keyDown(with: event)
            return
        }

        guard let document,
              let currentPage,
              document.pageCount > 0 else { return }
        let currentIndex = document.index(for: currentPage)
        let nextIndex = min(max(currentIndex + direction * arrowPageStep, 0), document.pageCount - 1)
        guard nextIndex != currentIndex, let page = document.page(at: nextIndex) else { return }
        go(to: page)
    }

    override func mouseDown(with event: NSEvent) {
        cancelPendingViewportRestore()
        pendingTap?.cancel()
        pendingTap = nil
        mouseDownPoint = event.locationInWindow
        mouseDownPageIndex = currentPage.flatMap { page in document.map { $0.index(for: page) } }
        mouseDownSelection = currentSelection?.string
        downHadModifiers = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        didDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        let dragged = didDrag || hypot(dx, dy) > 3
        let modifiers = downHadModifiers || !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        let initialPage = mouseDownPageIndex
        let initialSelection = mouseDownSelection
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let currentIndex = self.currentPage.flatMap { page in self.document.map { $0.index(for: page) } }
            let selectionChanged = self.currentSelection?.string != initialSelection
            let pageChanged = currentIndex != initialPage
            guard !pageChanged,
                  MacNativeClickFilter.shouldToggleChrome(
                    clickCount: event.clickCount,
                    dragged: dragged,
                    hasModifiers: modifiers,
                    selectionChanged: selectionChanged
                  ) else { return }
            self.onCleanContentClick?()
        }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        mouseDownPoint = nil
    }
}
