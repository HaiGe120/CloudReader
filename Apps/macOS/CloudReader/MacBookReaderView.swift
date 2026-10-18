import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

struct MacBookReaderView: View {
    @EnvironmentObject private var library: BookLibrary
    @StateObject private var progressRecorder = MacReaderProgressRecorder()
    @AppStorage("reader.pageLayout") private var pageLayoutRaw = "scroll"
    @AppStorage("reader.theme") private var themeRaw = "system"
    @AppStorage("reader.font") private var fontRaw = "systemSerif"
    @AppStorage("reader.fontSize") private var textSize = 20.0
    @AppStorage("reader.customBackground") private var customBackground = "F8F4EB"
    @AppStorage("reader.customForeground") private var customForeground = "292621"

    let book: Book
    @State private var text: String?
    @State private var selectedPassage = ""
    @State private var assistantContext = ""
    @State private var assistantSelectedText: String?
    @State private var isShowingAssistant = false
    @State private var isShowingAppearance = false

    private var currentBook: Book {
        library.books.first(where: { $0.id == book.id }) ?? book
    }

    private var readerBackground: Color {
        switch themeRaw {
        case "light": Color(red: 0.985, green: 0.982, blue: 0.968)
        case "sepia": Color(red: 0.957, green: 0.925, blue: 0.858)
        case "dark": Color(red: 0.075, green: 0.078, blue: 0.085)
        case "custom": MacReaderColors.color(hex: customBackground)
        default: Color(nsColor: .textBackgroundColor)
        }
    }

    private var readerForeground: Color {
        switch themeRaw {
        case "light": Color(red: 0.13, green: 0.13, blue: 0.13)
        case "sepia": Color(red: 0.25, green: 0.20, blue: 0.15)
        case "dark": Color(red: 0.88, green: 0.87, blue: 0.84)
        case "custom": MacReaderColors.color(hex: customForeground)
        default: Color(nsColor: .labelColor)
        }
    }

    private var readerFont: Font {
        switch fontRaw {
        case "systemSans": .system(size: textSize)
        case "rounded": .system(size: textSize, design: .rounded)
        case "georgia": .custom("Georgia", size: textSize)
        case "palatino": .custom("Palatino", size: textSize)
        case "avenir": .custom("Avenir Next", size: textSize)
        case "monospaced": .system(size: textSize, design: .monospaced)
        default: .system(size: textSize, design: .serif)
        }
    }

    private var readerNSFont: NSFont {
        switch fontRaw {
        case "systemSans": return NSFont.systemFont(ofSize: textSize)
        case "rounded":
            let base = NSFont.systemFont(ofSize: textSize)
            if let descriptor = base.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: descriptor, size: textSize) {
                return rounded
            }
            return base
        case "georgia": return NSFont(name: "Georgia", size: textSize) ?? serifFont(ofSize: textSize)
        case "palatino": return NSFont(name: "Palatino", size: textSize) ?? serifFont(ofSize: textSize)
        case "avenir": return NSFont(name: "Avenir Next", size: textSize) ?? .systemFont(ofSize: textSize)
        case "monospaced": return NSFont.monospacedSystemFont(ofSize: textSize, weight: .regular)
        default: return serifFont(ofSize: textSize)
        }
    }

    private func serifFont(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var body: some View {
        Group {
            if let url = library.fileURL(for: book) {
                reader(for: book.format, url: url)
            } else {
                ContentUnavailableView("Book file not found", systemImage: "doc.questionmark", description: Text("Remove this entry and import the book again."))
            }
        }
        .background(readerBackground)
        .overlay(alignment: .bottom) {
            if !selectedPassage.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedPassage, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy the selected passage")

                    Button(action: lookUpSelectedPassage) {
                        Label("Look Up", systemImage: "book")
                    }
                    .help("Look up the selected passage in Dictionary")

                    Button {
                        assistantContext = ""
                        assistantSelectedText = selectedPassage
                        isShowingAssistant = true
                    } label: {
                        Label("Ask AI", systemImage: "sparkles")
                    }
                    .help("Ask AI about the selected passage")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(readerForeground)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.38), lineWidth: 1) }
                .padding(.bottom, 22)
            }
        }
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    assistantContext = library.readingContext(for: book, maximumCharacters: 8_000) ?? ""
                    assistantSelectedText = nil
                    isShowingAssistant = true
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .labelStyle(.titleAndIcon)
                .help("Ask AI about this book")
                .accessibilityLabel("Ask AI about this book")

                Button {
                    library.toggleBookmark(book)
                } label: {
                    Image(systemName: book.isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(book.isBookmarked ? "Remove bookmark" : "Bookmark book")

                if book.format == .txt || book.format == .pdf {
                    Button {
                        isShowingAppearance = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .help("Reading appearance")
                }
            }
        }
        .onAppear {
            library.markOpened(book)
            loadTextIfNeeded()
        }
        .onDisappear {
            progressRecorder.flush()
        }
        .sheet(isPresented: $isShowingAssistant) {
            MacAIAssistantView(
                bookID: book.id,
                bookTitle: book.title,
                bookContext: assistantContext.isEmpty ? nil : assistantContext,
                bookDescription: library.briefDescription(for: book),
                selectedText: assistantSelectedText,
                contextDescription: assistantSelectedText == nil ? nil : "Selected passage from \(book.title)"
            )
                .frame(minWidth: 620, minHeight: 500)
        }
        .sheet(isPresented: $isShowingAppearance) {
            MacReaderAppearanceView()
                .frame(width: 440, height: 520)
        }
    }

    private func lookUpSelectedPassage() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let options: [NSView.DefinitionOptionKey: Any] = [
            .presentationType: NSView.DefinitionPresentationType.dictionaryApplication
        ]
        if let textView = selectedTextView(in: contentView) {
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            textView.showDefinition(for: nil, range: range, options: options)
            return
        }
        if let pdfView = selectedPDFView(in: contentView), !selectedPassage.isEmpty {
            let lookupText = NSAttributedString(string: selectedPassage)
            pdfView.showDefinition(
                for: lookupText,
                range: NSRange(location: 0, length: lookupText.length),
                options: options
            ) { _ in
                NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            }
        }
    }

    private func selectedTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.selectedRange().length > 0 {
            return textView
        }
        for child in view.subviews {
            if let selected = selectedTextView(in: child) { return selected }
        }
        return nil
    }

    private func selectedPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView,
           !(pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return pdfView
        }
        for child in view.subviews {
            if let selected = selectedPDFView(in: child) { return selected }
        }
        return nil
    }

    @ViewBuilder
    private func reader(for format: BookFormat, url: URL) -> some View {
        switch format {
        case .txt:
            if let text {
                MacTextReaderView(
                    book: book,
                    text: text,
                    progress: currentBook.progress,
                    pageLayoutRaw: pageLayoutRaw,
                    font: readerFont,
                    platformFont: readerNSFont,
                    fontIdentifier: fontRaw,
                    fontSize: textSize,
                    backgroundColor: readerBackground,
                    foregroundColor: readerForeground,
                    onProgressChanged: { progress in
                        progressRecorder.record(progress, for: book.id, in: library)
                    },
                    onSelectionChanged: { selectedPassage = $0 }
                )
            } else {
                ProgressView("Opening text…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .pdf:
            GeometryReader { geometry in
                MacPDFReaderView(
                    url: url,
                    progress: currentBook.progress,
                    pageLayoutRaw: pageLayoutRaw,
                    availableWidth: geometry.size.width,
                    backgroundColor: readerBackground,
                    onProgressChanged: { progress in
                        progressRecorder.record(progress, for: book.id, in: library)
                    },
                    onSelectionChanged: { selectedPassage = $0 }
                )
            }
        case .epub:
            MacEPUBReaderView(url: url)
        case .mobi, .azw3, .fb2, .cbz, .cbr:
            ContentUnavailableView(
                "Reader coming later",
                systemImage: book.format.symbol,
                description: Text("\(book.format.displayName) books can be kept in your library, but this format does not have a macOS reader yet.")
            )
        }
    }

    private func loadTextIfNeeded() {
        guard book.format == .txt, text == nil, let url = library.fileURL(for: book) else { return }
        text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .utf16))
    }
}

@MainActor
private final class MacReaderProgressRecorder: ObservableObject {
    private weak var library: BookLibrary?
    private var pendingUpdate: (bookID: UUID, progress: Double)?
    private var flushTask: Task<Void, Never>?

    func record(_ progress: Double, for bookID: UUID, in library: BookLibrary) {
        self.library = library
        pendingUpdate = (bookID, min(max(progress, 0), 1))
        // Persist once scrolling pauses instead of writing the whole library
        // index while the trackpad is still moving.
        flushTask?.cancel()

        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let update = pendingUpdate, let library else { return }
        pendingUpdate = nil
        library.updateProgress(for: update.bookID, to: update.progress)
    }
}

private struct MacTextReaderView: View {
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

    @State private var fullText: String
    @State private var paragraphs: [String]
    @State private var contentHash: Int
    @State private var pageGroupIndex = 0
    @State private var scrollGroupIndex: Int?
    @State private var paginationCacheSignature = ""
    @State private var paginationCache: [String] = []

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
        onSelectionChanged: @escaping (String) -> Void
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

        let content = "\(book.title)\n\n\(text)"
        _fullText = State(initialValue: content)
        _paragraphs = State(initialValue: content.components(separatedBy: "\n"))
        _contentHash = State(initialValue: content.hashValue)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = MacReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
            let pagesPerGroup = layout == .facingPages && geometry.size.width >= 760 ? 2 : 1
            let pageWidth = pagesPerGroup == 2
                ? max((geometry.size.width - 8) / 2, 280)
                : max(geometry.size.width, 300)
            let pageHeight = max(geometry.size.height - 48, 320)
            let paginationSignature = "\(book.id.uuidString)|\(contentHash)|\(layout.rawValue)|\(Int(pageWidth.rounded()))|\(Int(pageHeight.rounded()))|\(fontIdentifier)|\(fontSize)"
            let pageTexts = paginationCacheSignature == paginationSignature ? paginationCache : []
            let groupCount = MacReaderPagination.pageGroupCount(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            let safeGroupIndex = min(max(pageGroupIndex, 0), groupCount - 1)
            let firstPageIndex = safeGroupIndex * pagesPerGroup
            let visiblePageTexts = layout == .scroll ? paragraphs : Array(pageTexts[firstPageIndex..<min(firstPageIndex + pagesPerGroup, pageTexts.count)])

            Group {
                if layout == .scroll {
                    scrollingReader
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
                    restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
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
                    MacReaderPagination.pages(from: source, width: width, height: height, font: font)
                }.value
                guard !Task.isCancelled else { return }
                paginationCache = pages
                paginationCacheSignature = paginationSignature
                restorePage(pageCount: pages.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: progress) {
                if layout != .scroll {
                    restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
                }
            }
            .onChange(of: pageTexts.count) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: pageLayoutRaw) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: pagesPerGroup) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: geometry.size) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: fontIdentifier) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
            }
            .onChange(of: fontSize) {
                restorePage(pageCount: pageTexts.count, pagesPerGroup: pagesPerGroup)
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
                onProgressChanged(
                    MacReaderPagination.progress(
                        pageGroupIndex: pageGroupIndex,
                        pageCount: pageTexts.count,
                        pagesPerGroup: pagesPerGroup
                    )
                )
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
    }

    private var scrollingReader: some View {
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
                .frame(maxWidth: 780)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .padding(.horizontal, 32)
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
        let currentGroup = min(max(pageGroupIndex, 0), groupCount - 1)
        let firstPageIndex = currentGroup * pagesPerGroup
        let firstPage = firstPageIndex + 1
        let lastPage = min(firstPageIndex + pagesPerGroup, pages.count)

        return ZStack(alignment: .bottom) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<groupCount, id: \.self) { groupIndex in
                        let firstIndex = groupIndex * pagesPerGroup
                        HStack(spacing: 8) {
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

            HStack(spacing: 20) {
                Button {
                    withAnimation(.snappy(duration: 0.30, extraBounce: 0.02)) {
                        pageGroupIndex = max(pageGroupIndex - 1, 0)
                    }
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(currentGroup == 0)
                .accessibilityLabel(pagesPerGroup == 2 ? "Previous spread" : "Previous page")
                .keyboardShortcut(.leftArrow, modifiers: [])

                Text(pagesPerGroup == 2
                     ? "Pages \(firstPage)–\(lastPage) of \(pages.count)"
                     : "Page \(firstPage) of \(pages.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 145)
                    .accessibilityLabel(pagesPerGroup == 2
                        ? "Pages \(firstPage) to \(lastPage) of \(pages.count)"
                        : "Page \(firstPage) of \(pages.count)")

                Button {
                    withAnimation(.snappy(duration: 0.30, extraBounce: 0.02)) {
                        pageGroupIndex = min(pageGroupIndex + 1, groupCount - 1)
                    }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .disabled(currentGroup >= groupCount - 1)
                .accessibilityLabel(pagesPerGroup == 2 ? "Next spread" : "Next page")
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 10)
            .padding(.horizontal, 20)
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

    private func restorePage(pageCount: Int, pagesPerGroup: Int) {
        let restoredIndex = MacReaderPagination.pageGroupIndex(
            progress: progress,
            pageCount: pageCount,
            pagesPerGroup: pagesPerGroup
        )
        pageGroupIndex = restoredIndex
        scrollGroupIndex = restoredIndex
    }
}

private enum MacReaderPageLayout: String {
    case scroll
    case singlePage
    case facingPages
}

private enum MacReaderPagination {
    static func pages(from text: String, width: CGFloat, height: CGFloat, font: NSFont) -> [String] {
        guard !text.isEmpty else { return [""] }
        let safeWidth = max(width, 40)
        let safeHeight = max(height, font.ascender - font.descender)
        var remainder = text
        var result: [String] = []

        while !remainder.isEmpty {
            let upperBound = min(remainder.count, 4_000)
            var lower = 1
            var upper = upperBound
            var fittingCount = 1

            while lower <= upper {
                let candidateCount = (lower + upper) / 2
                let end = remainder.index(remainder.startIndex, offsetBy: candidateCount)
                let candidate = String(remainder[..<end])
                if measuredHeight(of: candidate, width: safeWidth, font: font) <= safeHeight {
                    fittingCount = candidateCount
                    lower = candidateCount + 1
                } else {
                    upper = candidateCount - 1
                }
            }

            if fittingCount >= remainder.count {
                result.append(remainder.trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            let fittingEnd = remainder.index(remainder.startIndex, offsetBy: min(fittingCount, remainder.count))
            var boundary = remainder[..<fittingEnd].lastIndex(where: \.isWhitespace)
            if let candidate = boundary,
               remainder.distance(from: remainder.startIndex, to: candidate) < fittingCount * 4 / 5 {
                boundary = nil
            }
            let pageEnd = boundary ?? fittingEnd
            let page = String(remainder[..<pageEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            let nextStart = boundary.map { remainder.index(after: $0) } ?? pageEnd
            remainder = String(remainder[nextStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result.isEmpty ? [""] : result
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

    static func pageGroupCount(pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        return max((count + groupSize - 1) / groupSize, 1)
    }

    static func pageGroupIndex(progress: Double, pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let boundedProgress = min(max(progress, 0), 1)
        return min(Int(boundedProgress * Double(count)), count - 1) / groupSize
    }

    static func progress(pageGroupIndex: Int, pageCount: Int, pagesPerGroup: Int) -> Double {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let groupCount = pageGroupCount(pageCount: count, pagesPerGroup: groupSize)
        let group = min(max(pageGroupIndex, 0), groupCount - 1)
        return Double(min(group * groupSize, count - 1)) / Double(count)
    }
}

private struct MacReaderAppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.pageLayout") private var pageLayoutRaw = "scroll"
    @AppStorage("reader.theme") private var themeRaw = "system"
    @AppStorage("reader.font") private var fontRaw = "systemSerif"
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.customBackground") private var customBackground = "F8F4EB"
    @AppStorage("reader.customForeground") private var customForeground = "292621"

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { MacReaderColors.color(hex: customBackground) },
            set: { customBackground = MacReaderColors.hex($0) }
        )
    }

    private var foregroundColor: Binding<Color> {
        Binding(
            get: { MacReaderColors.color(hex: customForeground) },
            set: { customForeground = MacReaderColors.hex($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page layout") {
                    Picker("Layout", selection: $pageLayoutRaw) {
                        Text("Scroll").tag("scroll")
                        Text("Single page").tag("singlePage")
                        Text("Two pages").tag("facingPages")
                    }
                    .pickerStyle(.segmented)
                    Text("Two pages appear side by side when the reader window is wide enough.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Page color") {
                    Picker("Theme", selection: $themeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Sepia").tag("sepia")
                        Text("Dark").tag("dark")
                        Text("Custom").tag("custom")
                    }
                    if themeRaw == "custom" {
                        ColorPicker("Paper", selection: backgroundColor, supportsOpacity: false)
                        ColorPicker("Text", selection: foregroundColor, supportsOpacity: false)
                    }
                }

                Section("Typography") {
                    Picker("Font", selection: $fontRaw) {
                        Text("New York").tag("systemSerif")
                        Text("System Sans").tag("systemSans")
                        Text("Rounded").tag("rounded")
                        Text("Georgia").tag("georgia")
                        Text("Palatino").tag("palatino")
                        Text("Avenir Next").tag("avenir")
                        Text("Monospaced").tag("monospaced")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $fontSize, in: 15...30, step: 1)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reading Appearance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum MacReaderColors {
    static func color(hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(cleaned, radix: 16) else { return .white }
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    static func hex(_ color: Color) -> String {
        let color = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return String(
            format: "%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}

private struct MacPDFReaderView: NSViewRepresentable {
    let url: URL
    let progress: Double
    let pageLayoutRaw: String
    let availableWidth: CGFloat
    let backgroundColor: Color
    let onProgressChanged: (Double) -> Void
    let onSelectionChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onSelectionChanged: onSelectionChanged)
    }

    func makeNSView(context: Context) -> MacNavigablePDFView {
        let view = MacNavigablePDFView()
        view.autoScales = true
        view.backgroundColor = NSColor(backgroundColor)
        view.pageShadowsEnabled = false
        view.displaysPageBreaks = false
        view.document = PDFDocument(url: url)
        configureLayout(of: view, preservingPage: false)
        context.coordinator.observeChanges(in: view)
        showSavedPage(in: view)
        return view
    }

    func updateNSView(_ view: MacNavigablePDFView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onSelectionChanged = onSelectionChanged
        view.backgroundColor = NSColor(backgroundColor)
        view.pageShadowsEnabled = false
        view.displaysPageBreaks = false
        if view.document?.documentURL?.standardizedFileURL != url.standardizedFileURL {
            view.document = PDFDocument(url: url)
            configureLayout(of: view, preservingPage: false)
            showSavedPage(in: view)
        } else {
            configureLayout(of: view, preservingPage: true)
        }
    }

    private func configureLayout(of view: PDFView, preservingPage: Bool) {
        let document = view.document
        let oldPageIndex = preservingPage ? view.currentPage.flatMap { document?.index(for: $0) } : nil
        let layout = MacReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
        let useFacingPages = layout == .facingPages && availableWidth >= 760
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
        guard view.displayMode != displayMode || view.displayDirection != direction else { return }
        view.displayMode = displayMode
        view.displayDirection = direction
        if let oldPageIndex,
           let document,
           let page = document.page(at: min(max(oldPageIndex, 0), max(document.pageCount - 1, 0))) {
            view.go(to: page)
        }
    }

    private func showSavedPage(in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        let pageIndex = min(max(Int((progress * Double(document.pageCount - 1)).rounded()), 0), document.pageCount - 1)
        if let page = document.page(at: pageIndex) { view.go(to: page) }
    }

    final class Coordinator {
        var onProgressChanged: (Double) -> Void
        var onSelectionChanged: (String) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onProgressChanged: @escaping (Double) -> Void, onSelectionChanged: @escaping (String) -> Void) {
            self.onProgressChanged = onProgressChanged
            self.onSelectionChanged = onSelectionChanged
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
                self.onProgressChanged(Double(document.index(for: page) + 1) / Double(document.pageCount))
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: view,
                queue: .main
            ) { [weak view, weak self] _ in
                guard let view, let self else { return }
                let passage = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.onSelectionChanged(passage)
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

private final class MacNavigablePDFView: PDFView {
    var arrowPageStep = 1

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
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
}

private struct MacEPUBReaderView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard view.previewItem?.previewItemURL.standardizedFileURL != url.standardizedFileURL else { return }
        view.previewItem = url as NSURL
    }
}
