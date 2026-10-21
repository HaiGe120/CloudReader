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
    @State private var isShowingAssistant = false
    @State private var isShowingAppearance = false
    @State private var selectedPassage = ""
    @State private var assistantContext: String?
    @State private var assistantSelectedText: String?
    @State private var assistantBookDescription: String?
    @State private var assistantContextDescription: String?
    @State private var isChromeVisible = true
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
        .background(Color(uiColor: readerPalette.background))
        .overlay(alignment: .bottom) {
            if isChromeVisible && capabilities.supportsSelection && !selectedPassage.isEmpty {
                selectedPassageActions.padding(.bottom, 16)
            }
        }
        .navigationTitle(isChromeVisible ? book.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isChromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar(isChromeVisible ? .visible : .hidden, for: .tabBar)
        .toolbar {
            if isChromeVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openAssistant() } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Ask AI about this book")
                        .accessibilityIdentifier("reader.askAI")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { library.toggleBookmark(currentBook) } label: {
                        Image(systemName: currentBook.isBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(currentBook.isBookmarked ? "Remove bookmark" : "Bookmark book")
                    .accessibilityIdentifier("reader.favorite")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isShowingAppearance = true } label: { Image(systemName: "textformat.size") }
                        .accessibilityLabel("Reading appearance")
                        .accessibilityIdentifier("reader.appearance")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isChromeVisible {
                ReaderChromeControls(
                    state: currentNavigationState,
                    capabilities: capabilities,
                    onNavigate: sendNavigationRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .statusBarHidden(!isChromeVisible)
        .onAppear { library.markOpened(book) }
        .onDisappear { library.flushPendingChanges() }
        .task(id: "\(bookURL?.absoluteString ?? "")|\(textLoadAttempt)") { await loadTextIfNeeded() }
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
            ReaderAppearanceSheet(capabilities: capabilities)
        }
    }

    @ViewBuilder
    private func readerContent(url: URL) -> some View {
        Group {
            switch book.format {
            case .pdf:
                GeometryReader { geometry in
                    let metrics = ReaderLayoutMetrics.resolve(
                        viewport: geometry.size,
                        pageLayout: ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll,
                        font: readerFont,
                        fontSize: CGFloat(fontSize)
                    )
                    PDFBookReader(
                        url: url,
                        progress: currentBook.progress,
                        twoPage: metrics.effectiveColumnCount == 2,
                        palette: readerPalette,
                        onProgressChanged: { library.updateProgress(for: book.id, to: $0) },
                        isChromeVisible: isChromeVisible,
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
                        isChromeVisible: isChromeVisible,
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
                    isChromeVisible: isChromeVisible,
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
                    isChromeVisible: isChromeVisible,
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
        setChromeVisible(!isChromeVisible)
    }

    private func setChromeVisible(_ visible: Bool) {
        guard visible != isChromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isChromeVisible = visible }
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
