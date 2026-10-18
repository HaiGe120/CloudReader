import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacLibraryView: View {
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @State private var searchText = ""
    @State private var isShowingAssistant = false
    @State private var isPresentingBookImporter = false
    @State private var isDropTargeted = false
    @State private var bookToRemove: Book?
    @State private var syncTask: Task<Void, Never>?

    private var visibleBooks: [Book] {
        let ordered = library.books.sorted { $0.addedAt > $1.addedAt }
        guard !searchText.isEmpty else { return ordered }
        return ordered.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var importTypes: [UTType] {
        let customTypes = ["epub", "mobi", "azw3", "fb2", "cbz", "cbr"]
            .compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
        return [.pdf, .plainText] + customTypes
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    MacLibraryBackdrop()

                    ScrollView {
                        if geometry.size.width >= 760 && geometry.size.height >= 480 {
                            expandedHome(height: geometry.size.height)
                        } else {
                            compactHome
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationDestination(for: Book.self) { book in
                MacBookReaderView(book: book)
            }
            .alert("CloudReader", isPresented: alertIsPresented) {
                Button("OK", role: .cancel) { library.alertMessage = nil }
            } message: {
                Text(library.alertMessage ?? "")
            }
            .confirmationDialog("Remove this book?", isPresented: removeDialogIsPresented, titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) {
                    if let bookToRemove { library.remove(bookToRemove) }
                    bookToRemove = nil
                }
                Button("Cancel", role: .cancel) { bookToRemove = nil }
            } message: {
                Text("The imported copy will be removed. The original file stays where it is.")
            }
            .sheet(isPresented: $isShowingAssistant) {
                MacAIAssistantView(bookTitle: nil, bookContext: nil)
                    .frame(minWidth: 620, minHeight: 500)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: importDroppedBooks)
        .overlay(alignment: .top) {
            if isDropTargeted {
                Label("Drop books to import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1) }
                    .padding(.top, 18)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isDropTargeted)
        .onReceive(NotificationCenter.default.publisher(for: .cloudReaderImportBooks)) { _ in
            presentBookImporter()
        }
        .onAppear(perform: scheduleSync)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scheduleSync() }
        }
        .onChange(of: library.books) { _, _ in scheduleSync() }
        .onChange(of: library.aiConversations) { _, _ in scheduleSync() }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } })
    }

    private var removeDialogIsPresented: Binding<Bool> {
        Binding(get: { bookToRemove != nil }, set: { if !$0 { bookToRemove = nil } })
    }

    @MainActor
    private func presentBookImporter() {
        guard !isPresentingBookImporter else { return }
        isPresentingBookImporter = true

        let panel = NSOpenPanel()
        panel.title = "Import Books"
        panel.prompt = "Import"
        panel.allowedContentTypes = importTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isPresentingBookImporter = false
            guard response == .OK, !panel.urls.isEmpty else { return }
            library.importBooks(from: panel.urls)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func importDroppedBooks(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var droppedURLs: [(Int, URL)] = []

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = Self.fileURL(from: item) else { return }
                lock.lock()
                droppedURLs.append((index, url))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            lock.lock()
            let urls = droppedURLs.sorted { $0.0 < $1.0 }.map(\.1)
            lock.unlock()
            guard !urls.isEmpty else { return }
            Task { @MainActor in library.importBooks(from: urls) }
        }
        return true
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private var compactHome: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            if let book = library.mostRecentlyRead {
                continueReading(book)
            }

            if library.books.isEmpty {
                emptyLibrary
            } else {
                searchField
                collection(minimumTileWidth: 148)
            }

            syncSummary
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 30)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }

    private func expandedHome(height: CGFloat) -> some View {
        let feature = library.mostRecentlyRead ?? library.books.first
        return HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let feature {
                    wideFeaturedBook(feature)
                } else {
                    emptyLibrary
                }
                syncSummary
            }
            .frame(maxWidth: 400, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your shelf")
                            .font(.system(size: 27, weight: .bold, design: .serif))
                        Text("A calm place to pick up any book.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("\(library.books.count) \(library.books.count == 1 ? "book" : "books")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                searchField
                collection(minimumTileWidth: 176)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .frame(maxWidth: 1450)
        .frame(minHeight: max(height - 28, 480), alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CLOUDREADER")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.secondary)
                Text("Library")
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.92))
            }

            Spacer(minLength: 0)

            MacLibraryCapsuleButton(
                title: "Ask AI",
                systemImage: "sparkles",
                accessibilityLabel: "Ask AI",
                width: 97,
                height: 48,
                tint: .labelColor
            ) {
                isShowingAssistant = true
            }
            .frame(width: 97, height: 48)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1)
                    .allowsHitTesting(false)
            }

            MacLibraryCapsuleButton(
                title: "Import",
                systemImage: "plus",
                accessibilityLabel: "Import books",
                width: 98,
                height: 48,
                tint: .labelColor,
                action: { presentBookImporter() }
            )
            .frame(width: 98, height: 48)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, 2)
    }

    private func wideFeaturedBook(_ book: Book) -> some View {
        NavigationLink(value: book) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.27, green: 0.39, blue: 0.36), Color(red: 0.15, green: 0.25, blue: 0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Circle()
                    .fill(.white.opacity(0.09))
                    .frame(width: 270, height: 270)
                    .blur(radius: 2)
                    .offset(x: 190, y: -100)
                HStack(alignment: .bottom, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(book.lastOpenedAt == nil ? "READY TO READ" : "CONTINUE READING", systemImage: "book.open")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.74))
                        Text(book.title)
                            .font(.system(size: 25, weight: .bold, design: .serif))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.white)
                        if let author = book.author {
                            Text(author)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.77))
                        }
                        ProgressView(value: book.progress)
                            .tint(.white.opacity(0.9))
                            .padding(.top, 5)
                        Text(book.progress > 0 ? "\(Int(book.progress * 100))% read" : "A short guide to the open shelf")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    MacBookCover(book: book)
                        .frame(width: 105, height: 152)
                        .rotationEffect(.degrees(3))
                        .padding(.bottom, 5)
                        .accessibilityHidden(true)
                }
                .padding(23)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(maxWidth: .infinity, minHeight: 254, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: Color(red: 0.17, green: 0.27, blue: 0.25).opacity(0.22), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(book.title)")
    }

    private var syncSummary: some View {
        Button(action: { openSettings() }) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("LIBRARY SYNC", systemImage: "arrow.triangle.2.circlepath.icloud")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Circle()
                        .fill(syncIndicatorColor)
                        .frame(width: 7, height: 7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(cloudSync.statusMessage)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .lineLimit(1)
                HStack(spacing: 18) {
                    Label("\(library.books.count) \(library.books.count == 1 ? "book" : "books")", systemImage: "books.vertical")
                    Label("\(library.books.filter(\.isBookmarked).count) saved", systemImage: "bookmark")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                if let error = cloudSync.errorMessage {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let lastSync = cloudSync.lastSync {
                    Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if !cloudSync.canSync {
                    Text("Connect and select one or more sync destinations in Settings to share this shelf with your other devices.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.42), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Open sync settings and review the connection status")
        .accessibilityLabel("Library sync. \(cloudSync.statusMessage). Open sync settings.")
    }

    private var syncIndicatorColor: Color {
        if cloudSync.errorMessage != nil { return .orange }
        if cloudSync.canSync { return .green }
        return .secondary
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.91, green: 0.78, blue: 0.62), Color(red: 0.76, green: 0.59, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 150, height: 150)
                    .blur(radius: 1)
                    .offset(x: 40, y: -45)

                HStack(alignment: .bottom, spacing: 12) {
                    MacBookSilhouette(color: Color(red: 0.39, green: 0.35, blue: 0.31), height: 126, rotation: -8)
                    MacBookSilhouette(color: Color(red: 0.69, green: 0.34, blue: 0.24), height: 153, rotation: 2)
                    MacBookSilhouette(color: Color(red: 0.26, green: 0.40, blue: 0.38), height: 112, rotation: 8)
                }
                .accessibilityHidden(true)
                .padding(.trailing, 36)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                Image(systemName: "sparkle")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityHidden(true)

                MacLibraryCapsuleButton(
                    title: "Import a book",
                    systemImage: "plus",
                    accessibilityLabel: "Import a book",
                    width: 150,
                    height: 42,
                    tint: .white,
                    action: { presentBookImporter() }
                )
                .frame(width: 150, height: 42)
                .background(.regularMaterial.opacity(0.55), in: Capsule())
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

            Text("A home for every book.")
                .font(.system(size: 28, weight: .bold, design: .serif))
                .padding(.top, 24)

            Text("Bring your reading together. Your library stays on this device, and your original files are left untouched.")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(spacing: 18) {
                Label("Private by design", systemImage: "desktopcomputer")
                Label("Ready offline", systemImage: "wifi.slash")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 28)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your library", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func collection(minimumTileWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("All books")
                    .font(.system(size: 25, weight: .bold, design: .serif))
                Spacer()
                Text("\(visibleBooks.count) \(visibleBooks.count == 1 ? "book" : "books")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if visibleBooks.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: 17)], alignment: .leading, spacing: 22) {
                    ForEach(visibleBooks) { book in
                        NavigationLink(value: book) {
                            MacBookTile(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(book.isBookmarked ? "Remove Favorite" : "Add Favorite", systemImage: book.isBookmarked ? "bookmark.slash" : "bookmark") {
                                library.toggleBookmark(book)
                            }
                            Divider()
                            Button("Remove from Library", systemImage: "trash", role: .destructive) {
                                bookToRemove = book
                            }
                        }
                    }
                }
            }
        }
    }

    private func continueReading(_ book: Book) -> some View {
        NavigationLink(value: book) {
            HStack(spacing: 16) {
                MacBookCover(book: book, compact: true)
                    .frame(width: 72, height: 102)
                VStack(alignment: .leading, spacing: 8) {
                    Text("PICK UP WHERE YOU LEFT OFF")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.system(size: 19, weight: .semibold, design: .serif))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Label(book.format.displayName, systemImage: book.format.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.48), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func scheduleSync() {
        guard cloudSync.canSync else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await cloudSync.sync(library: library)
        }
    }
}

private struct MacLibraryBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .windowBackgroundColor)
                Ellipse()
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.83, green: 0.48, blue: 0.34).opacity(0.30),
                            Color(red: 0.88, green: 0.68, blue: 0.43).opacity(0.28),
                            Color(red: 0.55, green: 0.68, blue: 0.60).opacity(0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: proxy.size.width * 0.98, height: 300)
                    .blur(radius: 46)
                    .offset(x: 60, y: -95)
                Ellipse()
                    .fill(Color(red: 0.66, green: 0.75, blue: 0.69).opacity(0.14))
                    .frame(width: 200, height: 220)
                    .blur(radius: 70)
                    .offset(x: -250, y: 250)
            }
            .ignoresSafeArea()
        }
    }
}

private struct MacLibraryCapsuleButton: View {
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let width: CGFloat
    let height: CGFloat
    let tint: NSColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: tint))
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct MacBookSilhouette: View {
    let color: Color
    let height: CGFloat
    let rotation: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.28)).frame(width: 3)
            }
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.45), lineWidth: 1).padding(9)
            }
            .frame(width: 67, height: height)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
    }
}

private struct MacBookTile: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MacBookCover(book: book)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if book.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(9)
                            .shadow(color: .black.opacity(0.18), radius: 4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if book.id == DemoBookInstaller.bookID {
                        Text("DEMO")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.3), in: Capsule())
                            .padding(9)
                    }
                }
            Text(book.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Text(book.author ?? book.format.displayName)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if book.progress > 0 {
                ProgressView(value: book.progress)
                    .tint(Color(red: 0.43, green: 0.51, blue: 0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MacBookCover: View {
    let book: Book
    var compact = false

    private var colors: [Color] {
        let stableIndex = book.id.uuidString.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 5 }
        switch stableIndex {
        case 0: return [Color(red: 0.31, green: 0.42, blue: 0.39), Color(red: 0.16, green: 0.27, blue: 0.25)]
        case 1: return [Color(red: 0.70, green: 0.38, blue: 0.29), Color(red: 0.42, green: 0.20, blue: 0.17)]
        case 2: return [Color(red: 0.39, green: 0.44, blue: 0.61), Color(red: 0.23, green: 0.27, blue: 0.42)]
        case 3: return [Color(red: 0.73, green: 0.60, blue: 0.40), Color(red: 0.47, green: 0.35, blue: 0.23)]
        default: return [Color(red: 0.57, green: 0.42, blue: 0.47), Color(red: 0.34, green: 0.25, blue: 0.34)]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: compact ? 12 : 17, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Rectangle()
                    .fill(.black.opacity(0.13))
                    .frame(width: 7)
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: book.format.symbol)
                        .font(.system(size: compact ? 15 : 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.78))
                    Spacer(minLength: 4)
                    Text(book.title)
                        .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .serif))
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(.white)
                    Rectangle()
                        .fill(.white.opacity(0.68))
                        .frame(width: proxy.size.width * 0.42, height: 1)
                }
                .padding(compact ? 10 : 14)
                .padding(.leading, 7)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 17, style: .continuous))
            .shadow(color: colors.last?.opacity(0.22) ?? .black.opacity(0.15), radius: compact ? 7 : 12, x: 0, y: 7)
        }
        .accessibilityLabel("Cover for \(book.title)")
    }
}
