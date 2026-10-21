import SwiftUI
import CloudReaderCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @EnvironmentObject private var imports: BookImportCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""
    @State private var isShowingImporter = false
    @State private var isShowingAssistant = false
    @State private var bookToDelete: Book?
    @State private var navigationPath: [Book] = []

    private var visibleBooks: [Book] {
        let ordered = library.books.sorted { $0.addedAt > $1.addedAt }
        guard !searchText.isEmpty else { return ordered }
        return ordered.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var importTypes: [UTType] {
        SharedBookInbox.contentTypes
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                let useExpandedHome = geometry.size.width >= 760 && geometry.size.height >= 480

                ZStack(alignment: .topTrailing) {
                    LibraryBackdrop()

                    if useExpandedHome {
                        ScrollView {
                            VStack(spacing: 0) {
                                expandedHeader
                                expandedHome(height: geometry.size.height - 76)
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                header
                                    .padding(.horizontal, 22)
                                    .padding(.top, 14)
                                compactHome()
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Book.self) { book in
                BookReaderView(book: book)
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: importTypes,
                allowsMultipleSelection: true,
                onCompletion: { result in
                    switch result {
                    case .success(let urls): imports.importFiles(urls, library: library)
                    case .failure(let error): library.alertMessage = error.localizedDescription
                    }
                }
            )
            .alert("CloudReader", isPresented: alertIsPresented) {
                Button("OK", role: .cancel) { library.alertMessage = nil }
            } message: {
                Text(library.alertMessage ?? "")
            }
            .confirmationDialog("Remove this book?", isPresented: deleteDialogIsPresented, titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) {
                    if let bookToDelete { library.remove(bookToDelete) }
                    bookToDelete = nil
                }
                Button("Cancel", role: .cancel) { bookToDelete = nil }
            } message: {
                Text("The imported copy will be removed. The original file stays where it is.")
            }
            .sheet(isPresented: $isShowingAssistant) {
                AIAssistantView(bookTitle: nil, bookContext: nil)
            }
            .overlay {
                if imports.isImporting {
                    ProgressView("Importing books…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onChange(of: imports.bookToOpen) {
                if let book = imports.bookToOpen { navigationPath = [book] }
            }
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(get: { library.alertMessage != nil }, set: { if !$0 { library.alertMessage = nil } })
    }

    private var deleteDialogIsPresented: Binding<Bool> {
        Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } })
    }

    private var libraryTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CLOUDREADER")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2.1)
                .foregroundStyle(.secondary)
            Text("Library")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(Color.primary.opacity(0.92))
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            libraryTitle
            Spacer(minLength: 0)
            headerActions
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }

    private var expandedHeader: some View {
        HStack(alignment: .top, spacing: 28) {
            HStack(alignment: .center, spacing: 16) {
                libraryTitle
                Spacer(minLength: 0)
                headerActions
            }
            .frame(maxWidth: 400, alignment: .leading)

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func compactHome() -> some View {
        VStack(alignment: .leading, spacing: 26) {
            if let book = library.mostRecentlyRead {
                continueReading(book)
            }

            if library.books.isEmpty {
                emptyLibrary
            } else {
                searchField
                collection
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .frame(maxWidth: horizontalSizeClass == .regular ? 1120 : .infinity)
        .frame(maxWidth: .infinity)
    }

    private var headerActions: some View {
        HStack(spacing: 16) {
            Button {
                isShowingAssistant = true
            } label: {
                Label("Ask AI", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 15)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .glassEffect(.clear.interactive(), in: Capsule())
            .accessibilityLabel("Ask AI")

            Button {
                isShowingImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .glassEffect(.clear.interactive(), in: Circle())
            .accessibilityLabel("Import books")
            .disabled(imports.isImporting)
        }
    }

    private func expandedHome(height: CGFloat) -> some View {
        let feature = library.mostRecentlyRead ?? library.books.first
        return HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 20) {
                if let feature {
                    wideFeaturedBook(feature)
                } else {
                    emptyLibrary
                }
                syncSummary
            }
            .frame(maxWidth: 400, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 18) {
                searchField
                if library.books.isEmpty {
                    emptyLibrary
                } else {
                    collection
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 26)
        .frame(maxWidth: 1450)
        .frame(minHeight: max(height - 28, 480), alignment: .topLeading)
        .frame(maxWidth: .infinity)
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
                            Text(author).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.77))
                        }
                        ProgressView(value: book.progress)
                            .tint(.white.opacity(0.9))
                            .padding(.top, 5)
                        Text(book.progress > 0 ? "\(Int(book.progress * 100))% read" : "A short guide to the open shelf")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    BookCover(book: book)
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
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: Color(red: 0.17, green: 0.27, blue: 0.25).opacity(0.22), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(book.title)")
    }

    private var syncSummary: some View {
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
            if let lastSync = cloudSync.lastSync {
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

    private var syncIndicatorColor: Color {
        if cloudSync.errorMessage != nil { return .orange }
        if cloudSync.canSync { return .green }
        return .secondary
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.91, green: 0.78, blue: 0.62), Color(red: 0.76, green: 0.59, blue: 0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 150, height: 150)
                    .blur(radius: 1)
                    .offset(x: 40, y: -45)

                HStack(alignment: .bottom, spacing: 12) {
                    BookSilhouette(color: Color(red: 0.39, green: 0.35, blue: 0.31), height: 126, rotation: -8)
                    BookSilhouette(color: Color(red: 0.69, green: 0.34, blue: 0.24), height: 153, rotation: 2)
                    BookSilhouette(color: Color(red: 0.26, green: 0.40, blue: 0.38), height: 112, rotation: 8)
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

                Button {
                    isShowingImporter = true
                } label: {
                    Label("Import a book", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.clear.interactive(), in: Capsule())
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityLabel("Import a book")
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
                FeatureNote(symbol: "iphone.gen3", title: "Private by design")
                FeatureNote(symbol: "wifi.slash", title: "Ready offline")
            }
            .padding(.top, 28)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your library", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
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

    private var collection: some View {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 176 : 142), spacing: 17)], alignment: .leading, spacing: 22) {
                    ForEach(visibleBooks) { book in
                        NavigationLink(value: book) {
                            BookTile(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                bookToDelete = book
                            } label: {
                                Label("Remove from Library", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func continueReading(_ book: Book) -> some View {
        NavigationLink(value: book) {
            HStack(spacing: 16) {
                BookCover(book: book, compact: true)
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
}

private struct LibraryBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color(uiColor: .systemGroupedBackground)
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.83, green: 0.48, blue: 0.34).opacity(0.40),
                                Color(red: 0.88, green: 0.68, blue: 0.43).opacity(0.40),
                                Color(red: 0.55, green: 0.68, blue: 0.60).opacity(0.31)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.98, height: 300)
                    .blur(radius: 46)
                    .offset(x: 60, y: -95)
                Ellipse()
                    .fill(Color(red: 0.66, green: 0.75, blue: 0.69).opacity(0.18))
                    .frame(width: 200, height: 220)
                    .blur(radius: 70)
                    .offset(x: -250, y: 250)
            }
            .ignoresSafeArea()
        }
    }
}

private struct BookSilhouette: View {
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

private struct FeatureNote: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct BookTile: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            BookCover(book: book)
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

private struct BookCover: View {
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
