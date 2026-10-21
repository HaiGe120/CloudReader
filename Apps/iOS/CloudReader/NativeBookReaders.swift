import PDFKit
import SwiftUI
import UIKit
import CloudReaderCore

struct TextBookReader: View {
    let title: String
    let text: String
    let progress: Double
    let pageLayoutRaw: String
    let font: ReaderFont
    let fontSize: CGFloat
    let palette: ReaderPalette
    let onProgressChanged: (Double) -> Void
    let onAskAI: (String) -> Void
    var isChromeVisible = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }
    var onContentTap: () -> Void = {}
    var onSelectedTextChanged: (String) -> Void = { _ in }

    @State private var spreadIndex = 0
    @State private var fullText = ""
    @State private var paginatedPages: [String] = []
    @State private var readyPaginationRequest: TextPaginationRequest?
    @State private var restoredSpreadIndex: Int?
    @State private var lastNavigationRequestID: UUID?
    @State private var sourceTextOffset = 0
    @State private var hasSourceTextLocation = false
    @State private var pendingLocalProgress: Double?

    var body: some View {
        GeometryReader { geometry in
            let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
            let metrics = ReaderLayoutMetrics.resolve(
                viewport: geometry.size,
                pageLayout: layout,
                font: font,
                fontSize: fontSize
            )
            let pagesPerSpread = metrics.effectiveColumnCount
            if layout != .scroll {
                pagedReader(size: geometry.size, metrics: metrics, pagesPerSpread: pagesPerSpread)
            } else {
                let textColumnWidth = min(max(geometry.size.width - metrics.horizontalMargin * 2, 0), metrics.maximumProseWidth)
                SelectableBookTextView(
                    text: fullText,
                    font: font.uiFont(size: fontSize),
                    foreground: palette.foreground,
                    isScrollable: true,
                    initialProgress: progress,
                    onProgressChanged: onProgressChanged,
                    onAskAI: onAskAI,
                    onContentTap: onContentTap,
                    onSelectedTextChanged: onSelectedTextChanged,
                    navigationRequest: navigationRequest,
                    onNavigationStateChanged: onNavigationStateChanged
                )
                .frame(maxWidth: textColumnWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: palette.background))
            }
        }
        .background(Color(uiColor: palette.background))
        .onAppear {
            fullText = "\(title)\n\n\(text)"
            if (ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll) == .scroll {
                publishScrollState(progress)
            }
        }
        .onChange(of: text) { fullText = "\(title)\n\n\(text)" }
        .onChange(of: title) { fullText = "\(title)\n\n\(text)" }
    }

    private func pagedReader(size: CGSize, metrics: ReaderLayoutMetrics, pagesPerSpread: Int) -> some View {
        // Resolve prose width and margins from the measured viewport.
        let pageWidth = pagesPerSpread == 2
            ? max((size.width - metrics.gutter) / 2, 280)
            : max(size.width, 280)
        let pageHeight = max(size.height, 300)
        let request = TextPaginationRequest(
            text: fullText,
            width: pageWidth - metrics.horizontalMargin * 2,
            height: pageHeight - 32,
            font: metrics.font,
            fontSize: metrics.fontSize,
            pagesPerSpread: pagesPerSpread
        )

        return Group {
            if readyPaginationRequest == request {
                pagedReaderContent(
                    pageText: paginatedPages,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    pagesPerSpread: pagesPerSpread,
                    horizontalMargin: metrics.horizontalMargin,
                    gutter: metrics.gutter,
                    navigationRequest: navigationRequest
                )
            } else {
                ProgressView("Preparing pages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) {
            let task = Task.detached(priority: .userInitiated) {
                ReaderPagination.pages(
                    from: request.text,
                    width: request.width,
                    height: request.height,
                    font: request.font.uiFont(size: request.fontSize)
                )
            }
            let pages = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, !pages.isEmpty else { return }
            paginatedPages = pages
            readyPaginationRequest = request
            restoreProgress(pageCount: pages.count, pagesPerGroup: pagesPerSpread)
        }
    }

    private func publishScrollState(_ progress: Double) {
        onNavigationStateChanged(ReaderNavigationState(
            progress: progress,
            chapterIndex: 0,
            chapterCount: 1,
            chapterTitles: [],
            canNavigatePrevious: progress > 0.001,
            canNavigateNext: progress < 0.999
        ))
    }

    private func pagedReaderContent(
        pageText: [String],
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        pagesPerSpread: Int,
        horizontalMargin: CGFloat,
        gutter: CGFloat,
        navigationRequest: ReaderNavigationRequest?
    ) -> some View {
        let spreadCount = ReaderPagination.pageGroupCount(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)

        return TabView(selection: $spreadIndex) {
            ForEach(0..<spreadCount, id: \.self) { index in
                Group {
                    if pagesPerSpread == 2 {
                        HStack(spacing: gutter) {
                            pageColumn(pageText[index * pagesPerSpread], width: pageWidth, height: pageHeight, horizontalMargin: horizontalMargin)
                            if index * pagesPerSpread + 1 < pageText.count {
                                pageColumn(pageText[index * pagesPerSpread + 1], width: pageWidth, height: pageHeight, horizontalMargin: horizontalMargin)
                            } else {
                                Color.clear.frame(width: pageWidth, height: pageHeight)
                            }
                        }
                    } else {
                        pageColumn(pageText[index], width: pageWidth, height: pageHeight, horizontalMargin: horizontalMargin)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityLabel(pagesPerSpread == 2 ? "Two-page reading layout" : "One-page reading layout")
        .accessibilityHint("Swipe horizontally to turn pages.")
        .background(Color(uiColor: palette.background))
        .onAppear {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
            publishNavigationState(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: progress) {
            let isLocalUpdate = pendingLocalProgress.map { abs($0 - progress) < 0.0001 } ?? false
            pendingLocalProgress = nil
            if !isLocalUpdate { hasSourceTextLocation = false }
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: navigationRequest) { _, request in
            consume(request, pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: spreadIndex) {
            if restoredSpreadIndex == spreadIndex {
                restoredSpreadIndex = nil
                return
            }
            restoredSpreadIndex = nil
            guard spreadCount > 0 else { return }
            publishProgress(ReaderPagination.progress(
                pageGroupIndex: spreadIndex,
                pageCount: pageText.count,
                pagesPerGroup: pagesPerSpread
            ))
            sourceTextOffset = sourceOffset(forPageGroup: spreadIndex, pages: pageText, pagesPerGroup: pagesPerSpread)
            hasSourceTextLocation = true
            publishNavigationState(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
    }

    private func restoreProgress(pageCount: Int, pagesPerGroup: Int) {
        guard !text.isEmpty else { return }
        let restoredIndex = ReaderPagination.pageGroupIndex(
            progress: progress,
            pageCount: pageCount,
            pagesPerGroup: pagesPerGroup
        )
        let offsetIndex = ReaderTextLocation.groupIndex(
            forUTF16Offset: sourceTextOffset,
            in: paginatedPages,
            sourceText: fullText,
            pagesPerGroup: pagesPerGroup
        )
        let target = hasSourceTextLocation && !paginatedPages.isEmpty ? offsetIndex : restoredIndex
        restoredSpreadIndex = target
        spreadIndex = target
    }

    private func sourceOffset(forPageGroup group: Int, pages: [String], pagesPerGroup: Int) -> Int {
        return ReaderTextLocation.utf16Offset(atGroup: group, in: pages, sourceText: fullText, pagesPerGroup: pagesPerGroup)
    }

    private func consume(_ request: ReaderNavigationRequest?, pageCount: Int, pagesPerGroup: Int) {
        guard let request, request.id != lastNavigationRequestID else { return }
        lastNavigationRequestID = request.id
        let last = ReaderPagination.pageGroupCount(pageCount: pageCount, pagesPerGroup: pagesPerGroup) - 1
        guard last >= 0 else { return }
        let target: Int
        switch request.command {
        case .previous: target = max(0, spreadIndex - 1)
        case .next: target = min(last, spreadIndex + 1)
        case .previousChapter, .nextChapter, .chapter: target = 0
        case .seek(let value): target = ReaderPagination.pageGroupIndex(progress: value, pageCount: pageCount, pagesPerGroup: pagesPerGroup)
        }
        restoredSpreadIndex = target
        spreadIndex = min(max(target, 0), last)
        sourceTextOffset = sourceOffset(forPageGroup: spreadIndex, pages: paginatedPages, pagesPerGroup: pagesPerGroup)
        hasSourceTextLocation = true
        publishProgress(ReaderPagination.progress(pageGroupIndex: spreadIndex, pageCount: pageCount, pagesPerGroup: pagesPerGroup))
        publishNavigationState(pageCount: pageCount, pagesPerGroup: pagesPerGroup)
    }

    private func publishProgress(_ value: Double) {
        pendingLocalProgress = value
        onProgressChanged(value)
    }

    private func publishNavigationState(pageCount: Int, pagesPerGroup: Int) {
        let count = ReaderPagination.pageGroupCount(pageCount: pageCount, pagesPerGroup: pagesPerGroup)
        let first = spreadIndex * pagesPerGroup + 1
        let last = min(first + pagesPerGroup - 1, pageCount)
        let currentProgress = ReaderPagination.progress(pageGroupIndex: spreadIndex, pageCount: pageCount, pagesPerGroup: pagesPerGroup)
        onNavigationStateChanged(ReaderNavigationState(
            progress: currentProgress,
            pageRange: first <= last ? first...last : nil,
            pageCount: pageCount,
            chapterIndex: 0,
            chapterCount: 1,
            chapterTitles: [],
            canNavigatePrevious: spreadIndex > 0,
            canNavigateNext: spreadIndex + 1 < count
        ))
    }

    private func pageColumn(_ text: String, width: CGFloat, height: CGFloat, horizontalMargin: CGFloat) -> some View {
        SelectableBookTextView(
            text: text,
            font: font.uiFont(size: fontSize),
            foreground: palette.foreground,
            isScrollable: false,
            initialProgress: 0,
            onProgressChanged: { _ in },
            onAskAI: onAskAI,
            onContentTap: onContentTap,
            onSelectedTextChanged: onSelectedTextChanged
        )
        .padding(.horizontal, horizontalMargin)
        .padding(.vertical, 16)
        .frame(width: width, height: height, alignment: .topLeading)
    }

}

enum ReaderTextLocation {
    static func utf16Offset(atGroup group: Int, in pages: [String], sourceText: String, pagesPerGroup: Int) -> Int {
        guard !pages.isEmpty, pagesPerGroup > 0 else { return 0 }
        let starts = sourcePageOffsets(in: pages, sourceText: sourceText)
        return starts[min(max(group * pagesPerGroup, 0), starts.count - 1)]
    }

    static func groupIndex(forUTF16Offset offset: Int, in pages: [String], sourceText: String, pagesPerGroup: Int) -> Int {
        guard !pages.isEmpty, pagesPerGroup > 0 else { return 0 }
        let starts = sourcePageOffsets(in: pages, sourceText: sourceText)
        let boundedOffset = max(offset, 0)
        var pageIndex = 0
        for (index, start) in starts.enumerated() {
            if start > boundedOffset { break }
            pageIndex = index
        }
        return pageIndex / pagesPerGroup
    }

    private static func sourcePageOffsets(in pages: [String], sourceText: String) -> [Int] {
        let source = sourceText as NSString
        var cursor = 0
        return pages.map { page in
            let start = min(max(cursor, 0), source.length)
            let range = NSRange(location: start, length: source.length - start)
            let match = source.range(of: page, options: [], range: range)
            guard match.location != NSNotFound else {
                cursor = min(source.length, start + (page as NSString).length)
                return start
            }
            cursor = NSMaxRange(match)
            return match.location
        }
    }
}

struct TextPaginationRequest: Hashable, Sendable {
    let text: String
    let width: CGFloat
    let height: CGFloat
    let font: ReaderFont
    let fontSize: CGFloat
    let pagesPerSpread: Int
}

struct SelectableBookTextView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let foreground: UIColor
    let isScrollable: Bool
    let initialProgress: Double
    let onProgressChanged: (Double) -> Void
    let onAskAI: (String) -> Void
    var onContentTap: () -> Void = {}
    var onSelectedTextChanged: (String) -> Void = { _ in }
    var navigationRequest: ReaderNavigationRequest? = nil
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onAskAI: onAskAI, onContentTap: onContentTap, onSelectedTextChanged: onSelectedTextChanged, onNavigationStateChanged: onNavigationStateChanged)
    }

    func makeUIView(context: Context) -> ReadingTextView {
        let view = ReadingTextView()
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapContent(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = isScrollable
        view.contentInset = .zero
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onWillRestoreProgress = { [weak coordinator = context.coordinator] in coordinator?.isRestoringProgress = true }
        view.onDidRestoreProgress = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.finishRestore(in: view)
        }
        updateText(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: ReadingTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onProgressChanged = onProgressChanged
        coordinator.onAskAI = onAskAI
        coordinator.onContentTap = onContentTap
        coordinator.onSelectedTextChanged = onSelectedTextChanged
        coordinator.onNavigationStateChanged = onNavigationStateChanged
        view.isScrollEnabled = isScrollable
        if coordinator.renderedText != text || coordinator.renderedFont != font || coordinator.renderedForeground != foreground {
            updateText(view, coordinator: coordinator)
        } else if isScrollable,
                  abs(initialProgress - coordinator.lastAppliedProgress) > 1e-9,
                  coordinator.lastReportedProgress.map({ abs(initialProgress - $0) > 1e-9 }) ?? true {
            restoreProgress(in: view, coordinator: coordinator)
        }
        coordinator.consume(navigationRequest, in: view)
    }

    private var attributedText: NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: ReaderPagination.paragraphStyle(for: font)
            ]
        )
    }

    private func updateText(_ view: ReadingTextView, coordinator: Coordinator) {
        if isScrollable {
            if coordinator.renderedText == nil {
                restoreProgress(in: view, coordinator: coordinator)
            } else {
                view.pendingTextOffset = view.readingTextOffset
                coordinator.isRestoringProgress = true
            }
        }
        coordinator.renderedText = text
        coordinator.renderedFont = font
        coordinator.renderedForeground = foreground
        let selection = view.selectedRange
        view.attributedText = attributedText
        view.textColor = foreground
        if NSMaxRange(selection) <= (text as NSString).length { view.selectedRange = selection }
    }

    private func restoreProgress(in view: ReadingTextView, coordinator: Coordinator) {
        coordinator.isRestoringProgress = true
        coordinator.lastAppliedProgress = initialProgress
        view.readingProgress = initialProgress
        view.pendingProgress = initialProgress
        view.setNeedsLayout()
    }

    final class ReadingTextView: UITextView {
        var pendingProgress: Double?
        var readingProgress = 0.0
        var pendingTextOffset: Int?
        var readingTextOffset = 0
        var onWillRestoreProgress: (() -> Void)?
        var onDidRestoreProgress: (() -> Void)?
        private var lastLayoutSize = CGSize.zero

        override func layoutSubviews() {
            if isScrollEnabled, lastLayoutSize != .zero, lastLayoutSize != bounds.size, pendingProgress == nil, pendingTextOffset == nil {
                pendingTextOffset = readingTextOffset
            }
            if pendingProgress != nil || pendingTextOffset != nil { onWillRestoreProgress?() }
            super.layoutSubviews()
            lastLayoutSize = bounds.size
            if isScrollEnabled, let textOffset = pendingTextOffset, bounds.width > 0 {
                pendingTextOffset = nil
                let textLength = (text as NSString).length
                let boundedOffset = min(max(textOffset, 0), max(textLength - 1, 0))
                let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: boundedOffset, length: 0), actualCharacterRange: nil)
                let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                setContentOffset(CGPoint(x: 0, y: max(glyphRect.minY, 0)), animated: false)
                readingTextOffset = boundedOffset
                onDidRestoreProgress?()
                return
            }
            guard let progress = pendingProgress, bounds.width > 0, bounds.height > 0, contentSize.height > 0 else { return }
            pendingProgress = nil
            let distance = max(contentSize.height - bounds.height, 0)
            setContentOffset(CGPoint(x: 0, y: distance * min(max(progress, 0), 1)), animated: false)
            readingTextOffset = textOffset(at: contentOffset.y)
            onDidRestoreProgress?()
        }

        func textOffset(at verticalOffset: CGFloat) -> Int {
            let textLength = (text as NSString).length
            guard textLength > 0 else { return 0 }
            let glyph = layoutManager.glyphIndex(for: CGPoint(x: 1, y: max(verticalOffset, 0)), in: textContainer)
            return min(max(layoutManager.characterIndexForGlyph(at: glyph), 0), textLength - 1)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onProgressChanged: (Double) -> Void
        var onAskAI: (String) -> Void
        var onContentTap: () -> Void
        var onSelectedTextChanged: (String) -> Void
        var onNavigationStateChanged: (ReaderNavigationState) -> Void
        var lastNavigationRequestID: UUID?
        var renderedText: String?
        var renderedFont: UIFont?
        var renderedForeground: UIColor?
        var lastAppliedProgress = 0.0
        var lastReportedProgress: Double?
        var isRestoringProgress = false

        init(onProgressChanged: @escaping (Double) -> Void, onAskAI: @escaping (String) -> Void, onContentTap: @escaping () -> Void, onSelectedTextChanged: @escaping (String) -> Void, onNavigationStateChanged: @escaping (ReaderNavigationState) -> Void) {
            self.onProgressChanged = onProgressChanged
            self.onAskAI = onAskAI
            self.onContentTap = onContentTap
            self.onSelectedTextChanged = onSelectedTextChanged
            self.onNavigationStateChanged = onNavigationStateChanged
        }

        @objc func didTapContent(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !isRestoringProgress else { return }
            onContentTap()
        }

        func finishRestore(in view: ReadingTextView) {
            isRestoringProgress = false
            guard view.isScrollEnabled else { return }
            let distance = max(view.contentSize.height - view.bounds.height, 0)
            let progress = distance > 0 ? min(max(view.contentOffset.y / distance, 0), 1) : view.readingProgress
            onNavigationStateChanged(ReaderNavigationState(
                progress: progress,
                chapterIndex: 0,
                chapterCount: 1,
                canNavigatePrevious: progress > 0.001,
                canNavigateNext: progress < 0.999
            ))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view as? UITextView, view.selectedRange.length == 0 else { return false }
            var touchedView: UIView? = touch.view
            while let candidate = touchedView, candidate !== view {
                let typeName = NSStringFromClass(type(of: candidate))
                if typeName.localizedCaseInsensitiveContains("selection") || typeName.localizedCaseInsensitiveContains("menu") {
                    return false
                }
                touchedView = candidate.superview
            }
            let point = touch.location(in: view)
            let layoutPoint = CGPoint(
                x: point.x + view.contentOffset.x - view.textContainerInset.left,
                y: point.y + view.contentOffset.y - view.textContainerInset.top
            )
            let index = view.layoutManager.characterIndex(for: layoutPoint, in: view.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            let textLength = ((view.text ?? "") as NSString).length
            guard index < textLength else { return true }
            let attributes = view.attributedText.attributes(at: index, effectiveRange: nil)
            return attributes[.link] == nil && attributes[NSAttributedString.Key("NSLink")] == nil
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isRestoringProgress else { return }
            let distance = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
            guard distance > 0 else { return }
            let progress = min(max(scrollView.contentOffset.y / distance, 0), 1)
            if let textView = scrollView as? ReadingTextView {
                textView.readingProgress = progress
                textView.readingTextOffset = textView.textOffset(at: textView.contentOffset.y)
            }
            lastReportedProgress = progress
            onProgressChanged(progress)
            onNavigationStateChanged(ReaderNavigationState(
                progress: progress,
                chapterIndex: 0,
                chapterCount: 1,
                canNavigatePrevious: progress > 0.001,
                canNavigateNext: progress < 0.999
            ))
        }

        func consume(_ request: ReaderNavigationRequest?, in view: ReadingTextView) {
            guard let request, request.id != lastNavigationRequestID,
                  view.bounds.height > 0, view.contentSize.height > 0 else { return }
            lastNavigationRequestID = request.id
            let distance = max(view.contentSize.height - view.bounds.height, 0)
            let y: CGFloat
            switch request.command {
            case .previous: y = max(0, view.contentOffset.y - view.bounds.height * 0.85)
            case .next: y = min(distance, view.contentOffset.y + view.bounds.height * 0.85)
            case .previousChapter, .chapter(0): y = 0
            case .nextChapter, .chapter: y = distance
            case .seek(let progress): y = distance * min(max(progress, 0), 1)
            }
            isRestoringProgress = true
            view.setContentOffset(CGPoint(x: 0, y: y), animated: true)
            let progress = distance > 0 ? min(max(y / distance, 0), 1) : 0
            isRestoringProgress = false
            lastReportedProgress = progress
            onProgressChanged(progress)
            onNavigationStateChanged(ReaderNavigationState(
                progress: progress,
                chapterIndex: 0,
                chapterCount: 1,
                canNavigatePrevious: progress > 0.001,
                canNavigateNext: progress < 0.999
            ))
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isRestoringProgress else { return }
            let range = textView.selectedRange
            let text = (textView.text ?? "") as NSString
            guard range.length > 0, NSMaxRange(range) <= text.length else {
                onSelectedTextChanged("")
                return
            }
            onSelectedTextChanged(text.substring(with: range))
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let text = textView.text,
                  NSMaxRange(range) <= (text as NSString).length else { return nil }
            let passage = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !passage.isEmpty else { return nil }
            let askAI = UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.onAskAI(passage)
            }
            return UIMenu(children: [askAI] + suggestedActions)
        }
    }
}

struct PDFBookReader: UIViewRepresentable {
    let url: URL
    let progress: Double
    let twoPage: Bool
    let palette: ReaderPalette
    let onProgressChanged: (Double) -> Void
    var isChromeVisible = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }
    var onContentTap: () -> Void = {}
    var onSelectedTextChanged: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onNavigationStateChanged: onNavigationStateChanged, onContentTap: onContentTap, onSelectedTextChanged: onSelectedTextChanged)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = palette.background
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapContent(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        view.addGestureRecognizer(tap)
        configure(view)
        context.coordinator.loadDocument(url, in: view, progress: progress)
        context.coordinator.observeChanges(in: view)
        context.coordinator.consume(navigationRequest, in: view)
        context.coordinator.publishCurrentState(in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onProgressChanged = onProgressChanged
        coordinator.onNavigationStateChanged = onNavigationStateChanged
        coordinator.onContentTap = onContentTap
        coordinator.onSelectedTextChanged = onSelectedTextChanged
        if coordinator.loadedURL != url {
            coordinator.loadDocument(url, in: view, progress: progress)
        } else if coordinator.lastReportedProgress.map({ abs(progress - $0) > 1e-9 }) ?? true,
                  abs(progress - coordinator.lastAppliedProgress) > 1e-9 {
            coordinator.restoreProgress(progress, in: view)
        }
        if view.backgroundColor != palette.background { view.backgroundColor = palette.background }
        configure(view)
        coordinator.consume(navigationRequest, in: view)
    }

    private func configure(_ view: PDFView) {
        let mode: PDFDisplayMode = twoPage ? .twoUp : .singlePageContinuous
        let direction: PDFDisplayDirection = twoPage ? .horizontal : .vertical
        // Updating progress must not reset a reader's pinch-to-zoom level.
        if view.displayMode != mode { view.displayMode = mode }
        if view.displayDirection != direction { view.displayDirection = direction }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onProgressChanged: (Double) -> Void
        var onNavigationStateChanged: (ReaderNavigationState) -> Void
        var onContentTap: () -> Void
        var onSelectedTextChanged: (String) -> Void
        private var observers: [NSObjectProtocol] = []
        private(set) var loadedURL: URL?
        private(set) var lastAppliedProgress = 0.0
        private(set) var lastReportedProgress: Double?
        private var isRestoringProgress = false
        private var lastNavigationRequestID: UUID?

        init(onProgressChanged: @escaping (Double) -> Void, onNavigationStateChanged: @escaping (ReaderNavigationState) -> Void, onContentTap: @escaping () -> Void, onSelectedTextChanged: @escaping (String) -> Void) {
            self.onProgressChanged = onProgressChanged
            self.onNavigationStateChanged = onNavigationStateChanged
            self.onContentTap = onContentTap
            self.onSelectedTextChanged = onSelectedTextChanged
        }

        @objc func didTapContent(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onContentTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view as? PDFView else { return false }
            var touchedView: UIView? = touch.view
            while let candidate = touchedView, candidate !== view {
                let typeName = NSStringFromClass(type(of: candidate))
                if typeName.localizedCaseInsensitiveContains("selection")
                    || typeName.localizedCaseInsensitiveContains("menu")
                    || typeName.localizedCaseInsensitiveContains("link") {
                    return false
                }
                touchedView = candidate.superview
            }
            let point = touch.location(in: view)
            guard let page = view.page(for: point, nearest: true) else { return true }
            let pagePoint = view.convert(point, to: page)
            return page.annotation(at: pagePoint) == nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func consume(_ request: ReaderNavigationRequest?, in view: PDFView) {
            guard let request, request.id != lastNavigationRequestID,
                  let document = view.document, document.pageCount > 0,
                  let currentPage = view.currentPage ?? document.page(at: 0) else { return }
            lastNavigationRequestID = request.id
            let current = document.index(for: currentPage)
            let last = document.pageCount - 1
            let pageStep = view.displayMode == .twoUp ? 2 : 1
            let target: Int
            switch request.command {
            case .previous: target = max(0, current - pageStep)
            case .next: target = min(last, current + pageStep)
            case .previousChapter, .nextChapter, .chapter: target = current
            case .seek(let value): target = min(max(Int(floor(min(max(value, 0), 1) * Double(document.pageCount))), 0), last)
            }
            if let page = document.page(at: target) { view.go(to: page) }
            publishCurrentState(in: view)
        }

        func publishCurrentState(in view: PDFView) {
            guard let document = view.document, document.pageCount > 0,
                  let currentPage = view.currentPage ?? document.page(at: 0) else { return }
            let firstIndex = document.index(for: currentPage)
            let first = firstIndex + 1
            let last = min(firstIndex + (view.displayMode == .twoUp ? 1 : 0) + 1, document.pageCount)
            let progress = Double(last) / Double(document.pageCount)
            let state = ReaderNavigationState(
                progress: progress,
                pageRange: first...last,
                pageCount: document.pageCount,
                canNavigatePrevious: firstIndex > 0,
                canNavigateNext: last < document.pageCount
            )
            let documentID = ObjectIdentifier(document)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let currentDocument = view.document,
                      ObjectIdentifier(currentDocument) == documentID,
                      let visiblePage = view.currentPage ?? currentDocument.page(at: 0),
                      currentDocument.index(for: visiblePage) == firstIndex else { return }
                self.onNavigationStateChanged(state)
            }
        }

        func loadDocument(_ url: URL, in view: PDFView, progress: Double) {
            isRestoringProgress = true
            loadedURL = url
            lastReportedProgress = nil
            view.document = PDFDocument(url: url)
            restoreProgress(progress, in: view)
            isRestoringProgress = false
            publishCurrentState(in: view)
        }

        func restoreProgress(_ progress: Double, in view: PDFView) {
            lastAppliedProgress = progress
            guard let document = view.document, document.pageCount > 0 else { return }
            let boundedProgress = min(max(progress, 0), 1)
            let index = min(max(Int(ceil(boundedProgress * Double(document.pageCount) - 1e-9)) - 1, 0), document.pageCount - 1)
            guard let page = document.page(at: index), view.currentPage !== page else { return }
            isRestoringProgress = true
            view.go(to: page)
            isRestoringProgress = false
        }

        func observeChanges(in view: PDFView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak view, weak self] _ in
                guard let view,
                      let self,
                      !self.isRestoringProgress,
                      let document = view.document,
                      let page = view.currentPage,
                      document.pageCount > 0 else { return }
                let index = document.index(for: page)
                let progress = Double(index + 1) / Double(document.pageCount)
                self.lastReportedProgress = progress
                DispatchQueue.main.async { [weak view, weak self] in
                    guard let view, let self, let currentDocument = view.document,
                          let currentPage = view.currentPage,
                          currentDocument.index(for: currentPage) == index else { return }
                    self.onProgressChanged(progress)
                    self.publishCurrentState(in: view)
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: view,
                queue: .main
            ) { [weak view, weak self] _ in
                guard let view, let self else { return }
                let passage = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.onSelectedTextChanged(passage)
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
