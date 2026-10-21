import AppKit
import CloudReaderCore
import PDFKit
import SwiftUI

struct MacReaderPresentation: Equatable {
    let navigation: ReaderNavigationState
    let chromeVisible: Bool
    let appearanceAvailable: Bool
}

struct MacReaderPresentationKey: PreferenceKey {
    static let defaultValue: MacReaderPresentation? = nil
    static func reduce(value: inout MacReaderPresentation?, nextValue: () -> MacReaderPresentation?) {
        value = nextValue() ?? value
    }
}

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
    @State private var textLoadError: String?
    @State private var selectedPassage = ""
    @State private var assistantContext = ""
    @State private var assistantSelectedText: String?
    @State private var isShowingAssistant = false
    @State private var isShowingAppearance = false
    @State private var isChromeVisible = true
    @State private var navigationState = ReaderNavigationState(progress: 0, canNavigatePrevious: false, canNavigateNext: false)
    @State private var navigationRequest: ReaderNavigationRequest?

    private var currentBook: Book {
        library.books.first(where: { $0.id == book.id }) ?? book
    }

    private var readerBackground: Color {
        switch ReaderTheme(rawValue: themeRaw) ?? .system {
        case .light: Color(red: 0.985, green: 0.982, blue: 0.968)
        case .sepia: Color(red: 0.957, green: 0.925, blue: 0.858)
        case .dark: Color(red: 0.075, green: 0.078, blue: 0.085)
        case .custom: MacReaderColors.color(hex: customBackground)
        case .system: Color(nsColor: .textBackgroundColor)
        }
    }

    private var readerForeground: Color {
        switch ReaderTheme(rawValue: themeRaw) ?? .system {
        case .light: Color(red: 0.13, green: 0.13, blue: 0.13)
        case .sepia: Color(red: 0.25, green: 0.20, blue: 0.15)
        case .dark: Color(red: 0.88, green: 0.87, blue: 0.84)
        case .custom: MacReaderColors.color(hex: customForeground)
        case .system: Color(nsColor: .labelColor)
        }
    }

    private var readerFont: Font {
        switch ReaderFont(rawValue: fontRaw) ?? .systemSerif {
        case .systemSans: .system(size: textSize)
        case .rounded: .system(size: textSize, design: .rounded)
        case .georgia: .custom("Georgia", size: textSize)
        case .palatino: .custom("Palatino", size: textSize)
        case .avenir: .custom("Avenir Next", size: textSize)
        case .monospaced: .system(size: textSize, design: .monospaced)
        case .systemSerif: .system(size: textSize, design: .serif)
        }
    }

    private var readerNSFont: NSFont {
        switch ReaderFont(rawValue: fontRaw) ?? .systemSerif {
        case .systemSans: return NSFont.systemFont(ofSize: textSize)
        case .rounded:
            let base = NSFont.systemFont(ofSize: textSize)
            if let descriptor = base.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: descriptor, size: textSize) {
                return rounded
            }
            return base
        case .georgia: return NSFont(name: "Georgia", size: textSize) ?? serifFont(ofSize: textSize)
        case .palatino: return NSFont(name: "Palatino", size: textSize) ?? serifFont(ofSize: textSize)
        case .avenir: return NSFont(name: "Avenir Next", size: textSize) ?? .systemFont(ofSize: textSize)
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: textSize, weight: .regular)
        case .systemSerif: return serifFont(ofSize: textSize)
        }
    }

    private func serifFont(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var body: some View {
        ZStack {
            if let url = library.fileURL(for: book) {
                reader(for: book.format, url: url)
            } else {
                ContentUnavailableView("Book file not found", systemImage: "doc.questionmark", description: Text("Remove this entry and import the book again."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.content")
        .background(readerBackground)
        .overlay(alignment: .bottom) {
            if isChromeVisible, !selectedPassage.isEmpty {
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
            if isChromeVisible {
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
                .accessibilityIdentifier("reader.askAI")

                Button {
                    library.toggleBookmark(book)
                } label: {
                    Image(systemName: currentBook.isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(currentBook.isBookmarked ? "Remove favorite" : "Add favorite")

                if MacReaderBehaviorPolicy.supportsAppearance(for: book.format) {
                    Button {
                        isShowingAppearance = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .help("Reading appearance")
                    .accessibilityIdentifier("reader.appearance")
                }
                Button(action: toggleChrome) {
                    Label("Hide Reader Controls", systemImage: "rectangle.topthird.inset.filled")
                }
                .labelStyle(.iconOnly)
                .help("Hide reader controls (⌘⇧R)")
                .accessibilityLabel("Hide reader controls")
                .accessibilityIdentifier("reader.toggleControls")
              }
            }
        }
        .toolbar(isChromeVisible ? .visible : .hidden, for: .windowToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if MacReaderChromePolicy.reservesBottomInset(isChromeVisible: isChromeVisible) {
                ReaderChromeControls(
                    state: navigationState,
                    capabilities: capabilities(for: book.format),
                    onNavigate: submitNavigation
                )
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isChromeVisible {
                Button(action: toggleChrome) {
                    Label("Show Reader Controls", systemImage: "rectangle.topthird.inset.filled")
                        .labelStyle(.iconOnly)
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show reader controls (⌘⇧R or Escape)")
                .accessibilityLabel("Show reader controls")
                .accessibilityIdentifier("reader.toggleControls")
                .padding(12)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .background {
            HStack(spacing: 0) {
                Button("") { submitNavigation(.previous) }.keyboardShortcut(.pageUp, modifiers: [])
                Button("") { submitNavigation(.next) }.keyboardShortcut(.pageDown, modifiers: [])
                Button("") { toggleChrome() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .hidden()
        }
        .onAppear {
            library.markOpened(book)
        }
        .task(id: book.id) { await loadTextIfNeeded() }
        .onDisappear {
            progressRecorder.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            progressRecorder.flush()
        }
        .preference(key: MacReaderPresentationKey.self, value: MacReaderPresentation(
            navigation: navigationState, chromeVisible: isChromeVisible,
            appearanceAvailable: MacReaderBehaviorPolicy.supportsAppearance(for: book.format)
        ))
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
            MacReaderAppearanceView(supportsTypography: book.format != .pdf && book.format != .cbz && book.format != .cbr)
                .frame(width: 440, height: 520)
        }
    }

    private func capabilities(for format: BookFormat) -> ReaderCapabilities {
        MacReaderBehaviorPolicy.capabilities(for: format)
    }

    private func submitNavigation(_ command: ReaderNavigationCommand) {
        navigationRequest = ReaderNavigationRequest(command: command)
    }

    private func toggleChrome() { isChromeVisible.toggle() }

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
                    onSelectionChanged: { selectedPassage = $0 },
                    isChromeVisible: isChromeVisible,
                    navigationRequest: navigationRequest,
                    onNavigationStateChanged: { navigationState = $0 },
                    onContentTap: toggleChrome
                )
            } else if let textLoadError {
                ContentUnavailableView("Couldn’t open text", systemImage: "doc.text", description: Text(textLoadError))
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
                    onSelectionChanged: { selectedPassage = $0 },
                    isChromeVisible: isChromeVisible,
                    navigationRequest: navigationRequest,
                    onNavigationStateChanged: { navigationState = $0 },
                    onContentTap: toggleChrome
                )
            }
        case .epub:
            MacEPUBBookReader(
                bookID: book.id, url: url, progress: currentBook.progress,
                pageLayoutRaw: pageLayoutRaw, fontRaw: fontRaw, fontSize: textSize,
                background: readerBackground, foreground: readerForeground,
                onProgressChanged: { progressRecorder.record($0, for: book.id, in: library) },
                onSelectionChanged: { selectedPassage = $0 }, sourceFormat: .epub,
                isChromeVisible: isChromeVisible, navigationRequest: navigationRequest,
                onContentTap: toggleChrome, onNavigationStateChanged: { navigationState = $0 }
            )
        case .mobi, .azw3, .fb2:
            MacEPUBBookReader(
                bookID: book.id, url: url, progress: currentBook.progress,
                pageLayoutRaw: pageLayoutRaw, fontRaw: fontRaw, fontSize: textSize,
                background: readerBackground, foreground: readerForeground,
                onProgressChanged: { progressRecorder.record($0, for: book.id, in: library) },
                onSelectionChanged: { selectedPassage = $0 }, sourceFormat: format,
                isChromeVisible: isChromeVisible, navigationRequest: navigationRequest,
                onContentTap: toggleChrome, onNavigationStateChanged: { navigationState = $0 }
            )
        case .cbz, .cbr:
            MacComicBookReader(
                bookID: book.id, url: url, sourceFormat: format, progress: currentBook.progress,
                pageLayoutRaw: pageLayoutRaw, background: readerBackground,
                onProgressChanged: { progressRecorder.record($0, for: book.id, in: library) },
                isChromeVisible: isChromeVisible, navigationRequest: navigationRequest,
                onContentTap: toggleChrome, onNavigationStateChanged: { navigationState = $0 }
            )
        }
    }

    private func loadTextIfNeeded() async {
        guard book.format == .txt, text == nil, let url = library.fileURL(for: book) else { return }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
            if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            text = loaded
        } catch is CancellationError {
        } catch {
            textLoadError = error.localizedDescription
        }
    }
}

enum MacReaderBehaviorPolicy {
    static func capabilities(for format: BookFormat) -> ReaderCapabilities {
        switch format {
        case .txt: .text
        case .pdf: .pdf
        case .cbz, .cbr: .comic
        default: .reflowable
        }
    }

    static func supportsAppearance(for format: BookFormat) -> Bool {
        [.txt, .pdf, .epub, .mobi, .azw3, .fb2, .cbz, .cbr].contains(format)
    }
}

enum MacReaderChromePolicy {
    static let txtOwnsInlineNavigationFooter = false
    static func reservesBottomInset(isChromeVisible: Bool) -> Bool { isChromeVisible }
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
