import PDFKit
import QuickLook
import SwiftUI
import UIKit

struct BookReaderView: View {
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.pageLayout") private var pageLayoutRaw = ReaderPageLayout.scroll.rawValue
    @AppStorage("reader.theme") private var themeRaw = ReaderTheme.system.rawValue
    @AppStorage("reader.font") private var fontRaw = ReaderFont.systemSerif.rawValue
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.customBackground") private var customBackground = "F8F4EB"
    @AppStorage("reader.customForeground") private var customForeground = "292621"
    @State private var textContents = ""
    @State private var loadError: String?
    @State private var isShowingAssistant = false
    @State private var isShowingAppearance = false
    @State private var selectedPassage = ""
    @State private var assistantContext: String?
    @State private var assistantSelectedText: String?
    @State private var assistantBookDescription: String?
    @State private var assistantContextDescription: String?
    @State private var areReaderControlsVisible = false

    let book: Book

    private var currentBook: Book {
        library.books.first(where: { $0.id == book.id }) ?? book
    }

    private var bookURL: URL? { library.fileURL(for: book) }
    private var readerPalette: ReaderPalette {
        ReaderPalette.make(
            theme: ReaderTheme(rawValue: themeRaw) ?? .system,
            customBackground: customBackground,
            customForeground: customForeground
        )
    }
    private var readerFont: ReaderFont { ReaderFont(rawValue: fontRaw) ?? .systemSerif }

    var body: some View {
        GeometryReader { geometry in
            let immersiveReader = geometry.size.width >= 700
            let immersiveTwoPage = pageLayoutRaw == ReaderPageLayout.facingPages.rawValue && immersiveReader
            Group {
                if let url = bookURL {
                    switch book.format {
                    case .pdf:
                        ZStack(alignment: .bottom) {
                            PDFBookReader(
                                url: url,
                                progress: currentBook.progress,
                                twoPage: immersiveTwoPage,
                                palette: readerPalette,
                                onProgressChanged: { library.updateProgress(for: book.id, to: $0) },
                                onSelectionChanged: { selectedPassage = $0 }
                            )
                            if !selectedPassage.isEmpty {
                                HStack(spacing: 8) {
                                    Button {
                                        UIPasteboard.general.string = selectedPassage
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.system(size: 14, weight: .semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                    }
                                    .accessibilityHint("Copies the selected passage to the clipboard.")

                                    Button {
                                        openAssistant(about: selectedPassage)
                                    } label: {
                                        Label("Ask AI", systemImage: "sparkles")
                                            .font(.system(size: 14, weight: .semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                    }
                                    .accessibilityHint("Sends the selected PDF passage as context after you submit a question.")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(uiColor: readerPalette.foreground))
                                .glassEffect(.regular.interactive(), in: Capsule())
                                .padding(.bottom, 22)
                            }
                        }
                    case .txt:
                        TextBookReader(
                            title: book.title,
                            text: textContents,
                            progress: currentBook.progress,
                            pageLayoutRaw: pageLayoutRaw,
                            font: readerFont,
                            fontSize: CGFloat(fontSize),
                            palette: readerPalette,
                            readerControlsVisible: $areReaderControlsVisible,
                            onProgressChanged: { library.updateProgress(for: book.id, to: $0) },
                            onAskAI: { openAssistant(about: $0) }
                        )
                    case .epub:
                        QuickLookBookReader(url: url)
                    case .mobi, .azw3, .fb2, .cbz, .cbr:
                        unsupportedReader
                    }
                } else {
                    ContentUnavailableView("Book unavailable", systemImage: "book.closed", description: Text("The imported copy could not be found on this device."))
                }
            }
            .background(Color(uiColor: readerPalette.background))
            .navigationTitle(immersiveReader ? "" : book.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(immersiveReader)
            .toolbar(immersiveReader ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !immersiveReader {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { openAssistant() } label: {
                            Image(systemName: "sparkles")
                        }
                        .accessibilityLabel("Ask AI about this book")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            library.toggleBookmark(currentBook)
                        } label: {
                            Image(systemName: currentBook.isBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        .accessibilityLabel(currentBook.isBookmarked ? "Remove bookmark" : "Bookmark book")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isShowingAppearance = true } label: {
                            Image(systemName: "textformat.size")
                        }
                        .accessibilityLabel("Reading appearance")
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if immersiveReader {
                    immersiveReaderRail
                        // The adaptive iPhone Duo tab strip reserves a trailing
                        // rail in the root TabView. Center these reader actions
                        // on that same rail instead of the narrower page area.
                        // Keep the two control groups visually connected too.
                        .offset(x: 72, y: geometry.size.height * 0.10)
                }
            }
            .onAppear {
                library.markOpened(book)
                loadTextIfNeeded()
            }
            .sheet(isPresented: $isShowingAssistant) {
                AIAssistantView(
                    bookID: book.id,
                    bookTitle: book.title,
                    bookContext: assistantContext,
                    bookDescription: assistantBookDescription,
                    selectedText: assistantSelectedText,
                    contextDescription: assistantContextDescription
                )
            }
            .sheet(isPresented: $isShowingAppearance) {
                ReaderAppearanceSheet()
            }
            .alert("Couldn't open book", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    private var immersiveReaderRail: some View {
        VStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: readerPalette.foreground))
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel("Back to library")

            VStack(spacing: 8) {
                Button { openAssistant() } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 48, height: 48)
                }
                .glassEffect(.clear.interactive(), in: Circle())
                .accessibilityLabel("Ask AI about this book")

                Button { library.toggleBookmark(currentBook) } label: {
                    Image(systemName: currentBook.isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 48, height: 48)
                }
                .glassEffect(.clear.interactive(), in: Circle())
                .accessibilityLabel(currentBook.isBookmarked ? "Remove bookmark" : "Bookmark book")

                Button { isShowingAppearance = true } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 48, height: 48)
                }
                .glassEffect(.clear.interactive(), in: Circle())
                .accessibilityLabel("Reading appearance")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: readerPalette.foreground))
        }
        .padding(.trailing, 12)
        .padding(.top, 56)
        .padding(.bottom, 74)
    }

    private func toggleReaderControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            areReaderControlsVisible.toggle()
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })
    }

    private var unsupportedReader: some View {
        ContentUnavailableView {
            Label("Reader coming soon", systemImage: book.format.symbol)
        } description: {
            Text("\(book.format.displayName) books can be stored in your library, but the native reader for this format is not part of this first iOS build yet.")
        } actions: {
            Button("Back to Library") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func openAssistant(about passage: String? = nil) {
        assistantBookDescription = library.briefDescription(for: currentBook)
            ?? "No extractable description is available for this book."
        if let passage, !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            assistantContext = nil
            assistantSelectedText = passage
            assistantContextDescription = "The highlighted passage, book title, and brief description will be sent only when you ask."
        } else {
            assistantContext = library.readingContext(for: currentBook)
            assistantSelectedText = nil
            assistantContextDescription = assistantContext == nil
                ? "The book title and brief description will be sent only when you ask."
                : "The book title, brief description, and a short book excerpt will be sent only when you ask."
        }
        isShowingAssistant = true
    }

    private func loadTextIfNeeded() {
        guard book.format == .txt, let bookURL else { return }
        do {
            textContents = try String(contentsOf: bookURL, encoding: .utf8)
        } catch {
            do {
                textContents = try String(contentsOf: bookURL, encoding: .utf16)
            } catch {
                loadError = "This text file could not be decoded as UTF-8 or UTF-16."
            }
        }
    }
}

private struct TextBookReader: View {
    let title: String
    let text: String
    let progress: Double
    let pageLayoutRaw: String
    let font: ReaderFont
    let fontSize: CGFloat
    let palette: ReaderPalette
    @Binding var readerControlsVisible: Bool
    let onProgressChanged: (Double) -> Void
    let onAskAI: (String) -> Void

    @State private var spreadIndex = 0

    private var fullText: String { "\(title)\n\n\(text)" }

    var body: some View {
        GeometryReader { geometry in
            let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
            let pagesPerSpread = layout == .facingPages && geometry.size.width >= 700 ? 2 : 1
            if layout != .scroll {
                pagedReader(size: geometry.size, pagesPerSpread: pagesPerSpread, controlsVisible: readerControlsVisible)
            } else {
                let horizontalInset = min(max(geometry.size.width * 0.045, 22), 42)
                let textColumnWidth = min(max(geometry.size.width - horizontalInset * 2, 0), 780)
                SelectableBookTextView(
                    text: fullText,
                    font: font.uiFont(size: fontSize),
                    foreground: palette.foreground,
                    isScrollable: true,
                    initialProgress: progress,
                    onProgressChanged: onProgressChanged,
                    onAskAI: onAskAI
                )
                .frame(maxWidth: textColumnWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: palette.background))
            }
        }
        .background(Color(uiColor: palette.background))
    }

    private func pagedReader(size: CGSize, pagesPerSpread: Int, controlsVisible: Bool) -> some View {
        // Fill the reader viewport edge to edge. The glass controls float over
        // this canvas instead of reserving a blank strip that looks cut out.
        let pageWidth = pagesPerSpread == 2
            ? max((size.width - 18) / 2, 280)
            : min(max(size.width - 32, 280), 900)
        let pageHeight = max(size.height, 300)
        let pageText = ReaderPagination.pages(
            from: fullText,
            width: pageWidth - 32,
            height: pageHeight - 32,
            font: font.uiFont(size: fontSize)
        )
        let spreadCount = ReaderPagination.pageGroupCount(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)

        return TabView(selection: $spreadIndex) {
            ForEach(0..<spreadCount, id: \.self) { index in
                Group {
                    if pagesPerSpread == 2 {
                        HStack(spacing: 2) {
                            pageColumn(pageText[index * pagesPerSpread], width: pageWidth, height: pageHeight)
                            if index * pagesPerSpread + 1 < pageText.count {
                                pageColumn(pageText[index * pagesPerSpread + 1], width: pageWidth, height: pageHeight)
                            } else {
                                Color.clear.frame(width: pageWidth, height: pageHeight)
                            }
                        }
                    } else {
                        pageColumn(pageText[index], width: pageWidth, height: pageHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityLabel(pagesPerSpread == 2 ? "Two-page reading layout" : "One-page reading layout")
        .accessibilityHint("Swipe horizontally to turn pages. Tap once to show or hide reading controls.")
        .simultaneousGesture(TapGesture().onEnded { toggleReaderControls() })
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { spreadIndex = max(0, spreadIndex - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 38, height: 38)
                }
                .disabled(spreadIndex == 0)
                .accessibilityLabel(pagesPerSpread == 2 ? "Previous spread" : "Previous page")

                Spacer()
                let firstPage = spreadIndex * pagesPerSpread + 1
                let lastPage = min(firstPage + pagesPerSpread - 1, pageText.count)
                let pageLabel = pagesPerSpread == 2
                    ? "\(firstPage)–\(lastPage) of \(pageText.count)"
                    : "\(firstPage) of \(pageText.count)"
                Text(pageLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(pagesPerSpread == 2
                        ? "Pages \(firstPage) to \(lastPage) of \(pageText.count)"
                        : "Page \(firstPage) of \(pageText.count)")
                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { spreadIndex = min(spreadCount - 1, spreadIndex + 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 38, height: 38)
                }
                .disabled(spreadIndex >= spreadCount - 1)
                .accessibilityLabel(pagesPerSpread == 2 ? "Next spread" : "Next page")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: palette.foreground))
            .glassEffect(.clear.interactive(), in: Capsule())
            .frame(maxWidth: 270)
            .padding(.bottom, 4)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
            .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        }
        .background(Color(uiColor: palette.background))
        .onAppear {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: text) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: pageText.count) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: progress) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: spreadIndex) {
            guard spreadCount > 0 else { return }
            onProgressChanged(ReaderPagination.progress(
                pageGroupIndex: spreadIndex,
                pageCount: pageText.count,
                pagesPerGroup: pagesPerSpread
            ))
        }
        .onChange(of: fontSize) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: font.rawValue) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: pagesPerSpread) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: pageLayoutRaw) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
        .onChange(of: size) {
            restoreProgress(pageCount: pageText.count, pagesPerGroup: pagesPerSpread)
        }
    }

    private func restoreProgress(pageCount: Int, pagesPerGroup: Int) {
        guard !text.isEmpty else { return }
        spreadIndex = ReaderPagination.pageGroupIndex(
            progress: progress,
            pageCount: pageCount,
            pagesPerGroup: pagesPerGroup
        )
    }

    private func pageColumn(_ text: String, width: CGFloat, height: CGFloat) -> some View {
        SelectableBookTextView(
            text: text,
            font: font.uiFont(size: fontSize),
            foreground: palette.foreground,
            isScrollable: false,
            initialProgress: 0,
            onProgressChanged: { _ in },
            onAskAI: onAskAI
        )
        .padding(16)
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func toggleReaderControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            readerControlsVisible.toggle()
        }
    }
}

private struct SelectableBookTextView: UIViewRepresentable {
    let text: String
    let font: UIFont
    let foreground: UIColor
    let isScrollable: Bool
    let initialProgress: Double
    let onProgressChanged: (Double) -> Void
    let onAskAI: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onAskAI: onAskAI)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
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
        updateText(view, coordinator: context.coordinator)
        if isScrollable {
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                let distance = max(view.contentSize.height - view.bounds.height, 0)
                view.setContentOffset(CGPoint(x: 0, y: distance * initialProgress), animated: false)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onAskAI = onAskAI
        view.isScrollEnabled = isScrollable
        let key = "\(text)|\(font.fontName)|\(font.pointSize)|\(foreground)|"
        if context.coordinator.renderKey != key {
            context.coordinator.renderKey = key
            view.attributedText = attributedText
            view.textColor = foreground
            if isScrollable {
                context.coordinator.restoreProgress = initialProgress
                DispatchQueue.main.async {
                    view.layoutIfNeeded()
                    let distance = max(view.contentSize.height - view.bounds.height, 0)
                    view.setContentOffset(CGPoint(x: 0, y: distance * initialProgress), animated: false)
                }
            }
        }
    }

    private var attributedText: NSAttributedString {
        let paragraph = ReaderPagination.paragraphStyle(for: font)
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func updateText(_ view: UITextView, coordinator: Coordinator) {
        let key = "\(text)|\(font.fontName)|\(font.pointSize)|\(foreground)|"
        coordinator.renderKey = key
        view.attributedText = attributedText
        view.textColor = foreground
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onProgressChanged: (Double) -> Void
        var onAskAI: (String) -> Void
        var renderKey = ""
        var restoreProgress = 0.0

        init(onProgressChanged: @escaping (Double) -> Void, onAskAI: @escaping (String) -> Void) {
            self.onProgressChanged = onProgressChanged
            self.onAskAI = onAskAI
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let distance = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
            guard distance > 0 else { return }
            let progress = min(max(scrollView.contentOffset.y / distance, 0), 1)
            onProgressChanged(progress)
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

private struct PDFBookReader: UIViewRepresentable {
    let url: URL
    let progress: Double
    let twoPage: Bool
    let palette: ReaderPalette
    let onProgressChanged: (Double) -> Void
    let onSelectionChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressChanged: onProgressChanged, onSelectionChanged: onSelectionChanged)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = palette.background
        view.document = PDFDocument(url: url)
        configure(view)
        if let document = view.document, document.pageCount > 0 {
            let initialIndex = min(max(Int((progress * Double(document.pageCount)).rounded(.up)) - 1, 0), document.pageCount - 1)
            if let page = document.page(at: initialIndex) { view.go(to: page) }
        }
        context.coordinator.observeChanges(in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onProgressChanged = onProgressChanged
        context.coordinator.onSelectionChanged = onSelectionChanged
        if view.document == nil { view.document = PDFDocument(url: url) }
        view.backgroundColor = palette.background
        configure(view)
    }

    private func configure(_ view: PDFView) {
        view.autoScales = true
        view.displayMode = twoPage ? .twoUp : .singlePageContinuous
        view.displayDirection = twoPage ? .horizontal : .vertical
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
                let index = document.index(for: page)
                self.onProgressChanged(Double(index + 1) / Double(document.pageCount))
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

private struct QuickLookBookReader: View {
    @State private var previewURL: URL?

    let url: URL

    var body: some View {
        Color(uiColor: .systemBackground)
            .overlay {
                ProgressView("Opening EPUB…")
                    .tint(.secondary)
            }
            .quickLookPreview($previewURL)
            .onAppear { previewURL = url }
    }
}
