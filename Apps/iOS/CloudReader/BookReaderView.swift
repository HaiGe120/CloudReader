import CloudReaderCore
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
    @State private var loadedTextURL: URL?
    @State private var textLoadAttempt = 0
    @State private var pageSource = ReaderPageSource()
    @State private var preparingChat = false
    @AppStorage(ReaderTranslationTarget.enabledKey) private var translateWords = false
    @State private var assistantRequest: ReaderChatRequest?
    @State private var isShowingAppearance = false
    @State private var selectedPassage = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChromeVisible = false
    @State private var navigationRequest: ReaderNavigationRequest?
    @State private var navigationState: ReaderNavigationState?

    let book: Book

    private var currentBook: Book {
        library.books.first(where: { $0.id == book.id }) ?? book
    }

    private var bookURL: URL? { library.fileURL(for: currentBook) }
    private var readerPalette: ReaderPalette {
        ReaderPalette.make(
            theme: ReaderTheme(rawValue: themeRaw) ?? .system,
            customBackground: customBackground,
            customForeground: customForeground
        )
    }
    private var readerFont: ReaderFont { ReaderFont(rawValue: fontRaw) ?? .systemSerif }
    private var capabilities: ReaderCapabilities {
        switch book.format {
        case .pdf: .pdf
        case .cbz, .cbr: .comic
        case .txt: .text
        case .epub, .fb2: .reflowable
        case .mobi, .azw3: .comic
        }
    }
    private var currentNavigationState: ReaderNavigationState {
        navigationState ?? ReaderNavigationState(
            progress: currentBook.progress,
            canNavigatePrevious: currentBook.progress > 0,
            canNavigateNext: currentBook.progress < 1
        )
    }

    var body: some View {
        Group {
            if let url = bookURL {
                readerContent(url: url)
            } else {
                ContentUnavailableView("Book unavailable", systemImage: "book.closed", description: Text("The imported copy could not be found on this device."))
            }
        }
        .environment(\.readerPageSource, pageSource)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            compactProgress
                .opacity(isChromeVisible || navigationState == nil ? 0 : 1)
                .accessibilityHidden(isChromeVisible || navigationState == nil)
                .allowsHitTesting(!isChromeVisible && navigationState != nil)
        }
        .background { Color(uiColor: readerPalette.background).ignoresSafeArea() }
        .overlay(alignment: .top) {
            if isChromeVisible || navigationState == nil { readerToolbar }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if isChromeVisible {
                    if capabilities.supportsSelection && !selectedPassage.isEmpty {
                        selectedPassageActions
                    }
                    ReaderChromeControls(
                        state: currentNavigationState,
                        capabilities: capabilities,
                        onNavigate: sendNavigationRequest
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: 580)
        }
        .overlay {
            if translateWords, let word = ReaderWordTranslation.englishWord(selectedPassage), assistantRequest == nil {
                SelectionTranslationOverlay(word: word, selectionRect: pageSource.selectionRect)
                    .id(word)
            }
        }
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .statusBarHidden(false)
        .onAppear { library.markOpened(book) }
        .onDisappear { library.flushPendingChanges() }
        .task(id: "\(bookURL?.absoluteString ?? "")|\(textLoadAttempt)") { await loadTextIfNeeded() }
        .onDisappear { pageSource.capture = nil }
        .sheet(item: $assistantRequest) { request in
            AIAssistantView(
                bookID: request.book.id,
                bookTitle: request.book.title,
                bookContext: request.excerpt,
                bookDescription: request.description,
                selectedText: request.passage,
                contextDescription: request.location
            )
        }
        .sheet(isPresented: $isShowingAppearance) {
            ReaderAppearanceSheet(capabilities: capabilities)
        }
    }

    private var compactProgress: some View {
        let progress = currentNavigationState.progress
        return Button(action: toggleChrome) {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.readerAccent)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color(uiColor: readerPalette.foreground))
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 22)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reading progress")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        .accessibilityHint("Shows reading controls")
        .accessibilityIdentifier("reader.compactProgress")
    }

    private var readerToolbar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: { toolbarIcon("chevron.backward") }
                .accessibilityLabel("Back to library")
            Text(book.title)
                .font(.system(.headline, design: .serif))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button { openAssistant() } label: {
                if preparingChat { ProgressView().frame(width: 44, height: 44) }
                else { toolbarIcon("sparkles") }
            }
                .disabled(preparingChat)
                .accessibilityLabel(preparingChat ? "Preparing reading context" : "Ask AI about this book")
                .accessibilityIdentifier("reader.askAI")
            Button { library.toggleBookmark(currentBook) } label: {
                toolbarIcon(currentBook.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .accessibilityLabel(currentBook.isBookmarked ? "Remove bookmark" : "Bookmark book")
            .accessibilityIdentifier("reader.favorite")
            Button { isShowingAppearance = true } label: { toolbarIcon("textformat.size") }
                .accessibilityLabel("Reading appearance")
                .accessibilityIdentifier("reader.appearance")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: Capsule())
        .background(Color(uiColor: readerPalette.background).opacity(0.90), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: 680)
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func readerContent(url: URL) -> some View {
        Group {
            switch book.format {
            case .pdf:
                GeometryReader { geometry in
                    let layout = ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll
                    let metrics = ReaderLayoutMetrics.resolve(
                        viewport: geometry.size,
                        pageLayout: layout,
                        font: readerFont,
                        fontSize: CGFloat(fontSize)
                    )
                    PDFBookReader(
                        url: url,
                        progress: currentBook.progress,
                        pageLayout: layout == .facingPages && metrics.effectiveColumnCount == 1 ? .singlePage : layout,
                        palette: readerPalette,
                        onProgressChanged: { library.updateProgress(for: book.id, to: $0) },
                        navigationRequest: navigationRequest,
                        onNavigationStateChanged: navigationChanged,
                        onContentTap: toggleChrome,
                        onSelectedTextChanged: { selectedPassage = $0 }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            case .txt:
                if loadedTextURL == url {
                    TextBookReader(
                        title: book.title,
                        text: textContents,
                        progress: currentBook.progress,
                        pageLayoutRaw: pageLayoutRaw,
                        font: readerFont,
                        fontSize: CGFloat(fontSize),
                        palette: readerPalette,
                        onProgressChanged: { library.updateProgress(for: book.id, to: $0) },
                        onAskAI: { openAssistant(about: $0) },
                        navigationRequest: navigationRequest,
                        onNavigationStateChanged: navigationChanged,
                        onContentTap: toggleChrome,
                        onSelectedTextChanged: { selectedPassage = $0 }
                    )
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't open text", systemImage: "doc.text")
                    } description: { Text(loadError) } actions: {
                        Button("Try Again") { textLoadAttempt += 1 }
                    }
                } else {
                    ProgressView("Opening book…")
                }
            case .epub, .fb2:
                EPUBBookReader(
                    bookID: book.id,
                    url: url,
                    sourceFormat: book.format,
                    progress: currentBook.progress,
                    pageLayout: ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll,
                    font: readerFont,
                    fontSize: CGFloat(fontSize),
                    palette: readerPalette,
                    navigationRequest: navigationRequest,
                    onNavigationStateChanged: navigationChanged,
                    onContentTap: toggleChrome,
                    onSelectedTextChanged: { selectedPassage = $0 },
                    onAskAI: { openAssistant(about: $0) }
                )
            case .cbz:
                CBZBookReader(
                    bookID: book.id,
                    url: url,
                    progress: currentBook.progress,
                    pageLayout: ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll,
                    palette: readerPalette,
                    navigationRequest: navigationRequest,
                    onNavigationStateChanged: navigationChanged,
                    onContentTap: toggleChrome
                )
            case .mobi, .azw3, .cbr:
                unsupportedReader
            }
        }
        .accessibilityIdentifier("reader.content")
        .accessibilityHint(isChromeVisible ? "Double tap the page to hide reading controls." : "Double tap the page to show reading controls.")
        .accessibilityAction(named: Text(isChromeVisible ? "Hide reading controls" : "Show reading controls")) {
            toggleChrome()
        }
    }

    private var selectedPassageActions: some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = selectedPassage
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .accessibilityHint("Copies the selected passage to the clipboard.")
            Button { openAssistant(about: selectedPassage) } label: {
                Label("Ask AI", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .accessibilityHint("Sends the selected passage as context after you submit a question.")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: readerPalette.foreground))
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var unsupportedReader: some View {
        ContentUnavailableView {
            Label("Reader coming soon", systemImage: book.format.symbol)
        } description: {
            Text("\(book.format.displayName) books can be stored in your library, but the native reader for this format is not part of this first iOS build yet.")
        } actions: {
            Button("Back to Library") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func sendNavigationRequest(_ command: ReaderNavigationCommand) {
        navigationRequest = ReaderNavigationRequest(command: command)
    }

    private func navigationChanged(_ state: ReaderNavigationState) {
        guard state != navigationState else { return }
        navigationState = state
        if abs(currentBook.progress - state.progress) > 0.0001 {
            library.updateProgress(for: book.id, to: state.progress)
        }
    }

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isChromeVisible.toggle() }
    }

    private func openAssistant(about passage: String? = nil) {
        guard !preparingChat else { return }
        preparingChat = true
        Task { @MainActor in
            defer { preparingChat = false }
            assistantRequest = await pageSource.chatRequest(for: currentBook, selection: passage, library: library)
        }
    }

    private func loadTextIfNeeded() async {
        guard book.format == .txt, let bookURL, loadedTextURL != bookURL else { return }
        loadError = nil
        let task = Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: bookURL, encoding: .utf8))
                ?? (try? String(contentsOf: bookURL, encoding: .utf16))
        }
        let contents = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return }
        if let contents {
            textContents = contents
            loadedTextURL = bookURL
        } else {
            loadError = "This text file could not be read as UTF-8 or UTF-16."
        }
    }
}
