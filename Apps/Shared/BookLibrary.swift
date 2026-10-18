import Combine
import Foundation
import PDFKit
import SwiftUI

@MainActor
final class BookLibrary: ObservableObject {
    static let shared = BookLibrary()

    @Published private(set) var books: [Book] = []
    @Published private(set) var deletedBooks: [BookDeletion] = []
    @Published private(set) var aiConversations: [AIConversationRecord] = []
    @Published private(set) var deletedAIConversations: [AIConversationDeletion] = []
    @Published var alertMessage: String?

    private let fileManager = FileManager.default
    private let folderName = "CloudReader"

    init() {
        load()
    }

    var mostRecentlyRead: Book? {
        books.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    func importBooks(from urls: [URL]) {
        var imported = 0
        var rejected: [String] = []

        for source in urls {
            let hasAccess = source.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { source.stopAccessingSecurityScopedResource() }
            }

            guard let format = BookFormat(fileExtension: source.pathExtension) else {
                rejected.append(source.lastPathComponent)
                continue
            }

            do {
                let directory = try booksDirectory()
                let storedName = "\(UUID().uuidString).\(format.rawValue)"
                let destination = directory.appendingPathComponent(storedName)
                try fileManager.copyItem(at: source, to: destination)

                let title = source.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let briefDescription = Self.inferredBriefDescription(
                    from: Self.descriptionSource(at: destination, format: format),
                    title: title
                )
                books.insert(Book(title: title, briefDescription: briefDescription, fileName: storedName, format: format), at: 0)
                imported += 1
            } catch {
                rejected.append(source.lastPathComponent)
            }
        }

        save()

        if imported > 0 && rejected.isEmpty {
            alertMessage = "Added \(imported) \(imported == 1 ? "book" : "books") to your library."
        } else if imported > 0 {
            alertMessage = "Added \(imported) \(imported == 1 ? "book" : "books"). Skipped unsupported or unavailable files: \(rejected.joined(separator: ", "))."
        } else if !rejected.isEmpty {
            alertMessage = "These files could not be added. Choose EPUB, PDF, TXT, MOBI, AZW3, FB2, CBZ, or CBR books."
        }
    }

    func fileURL(for book: Book) -> URL? {
        guard Self.isSafeFileName(book.fileName) else { return nil }
        guard let directory = try? booksDirectory() else { return nil }
        let url = directory.appendingPathComponent(book.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func markOpened(_ book: Book) {
        update(book.id) { $0.lastOpenedAt = .now }
    }

    func toggleBookmark(_ book: Book) {
        update(book.id) { $0.isBookmarked.toggle() }
    }

    func updateProgress(for bookID: UUID, to progress: Double) {
        let progress = min(max(progress, 0), 1)
        guard let book = books.first(where: { $0.id == bookID }), abs(book.progress - progress) >= 0.01 else { return }
        update(bookID) { $0.progress = progress }
    }

    func remove(_ book: Book) {
        if let url = fileURL(for: book) {
            try? fileManager.removeItem(at: url)
        }
        books.removeAll { $0.id == book.id }
        deletedBooks.removeAll { $0.bookID == book.id }
        deletedBooks.append(BookDeletion(bookID: book.id, deletedAt: .now))
        save()
    }

    func data(for book: Book) -> Data? {
        guard let url = fileURL(for: book) else { return nil }
        return try? Data(contentsOf: url)
    }

    func readingContext(for book: Book, maximumCharacters: Int = 18_000) -> String? {
        guard let url = fileURL(for: book) else { return nil }
        let contents: String?
        switch book.format {
        case .txt:
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16))
        case .pdf:
            contents = PDFDocument(url: url)?.string
        case .epub, .mobi, .azw3, .fb2, .cbz, .cbr:
            contents = nil
        }
        guard let contents, !contents.isEmpty else { return nil }
        if contents.count <= maximumCharacters { return contents }
        return String(contents.prefix(maximumCharacters)) + "\n\n[Context shortened to fit the AI request. The source book stays on this device.]"
    }

    func briefDescription(for book: Book) -> String? {
        if let savedDescription = book.briefDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !savedDescription.isEmpty {
            return savedDescription
        }
        guard let url = fileURL(for: book) else { return nil }
        return Self.inferredBriefDescription(from: Self.descriptionSource(at: url, format: book.format), title: book.title)
    }

    func installDemoBookIfNeeded() {
        let seedKey = "cloudreader.demoBookInstalled.v1"
        if let demoIndex = books.firstIndex(where: { $0.id == DemoBookInstaller.bookID }), books[demoIndex].briefDescription == nil {
            books[demoIndex].briefDescription = DemoBookInstaller.briefDescription
            books[demoIndex].modifiedAt = .now
            save()
        }
        guard !UserDefaults.standard.bool(forKey: seedKey),
              let source = Bundle.main.url(forResource: "CloudReader_Field_Guide", withExtension: "txt") else { return }

        do {
            let fileName = "demo-cloudreader-field-guide.txt"
            let directory = try booksDirectory()
            let destination = directory.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }

            if !books.contains(where: { $0.id == DemoBookInstaller.bookID }) {
                var demo = Book(
                    id: DemoBookInstaller.bookID,
                    title: "The Open Shelf",
                    author: "The CloudReader Project",
                    briefDescription: DemoBookInstaller.briefDescription,
                    fileName: fileName,
                    format: .txt
                )
                let releaseDate = Date(timeIntervalSince1970: 1_767_225_600)
                demo.addedAt = releaseDate
                demo.modifiedAt = releaseDate
                books.append(demo)
                save()
            }
            UserDefaults.standard.set(true, forKey: seedKey)
        } catch {
            alertMessage = "CloudReader couldn't install its sample book. Check the available storage on this device."
        }
    }

    func applySyncedBook(_ book: Book, contents: Data) {
        do {
            var localBook = book
            localBook.fileName = "sync-\(book.id.uuidString).\(book.format.rawValue)"
            let directory = try booksDirectory()
            let destination = directory.appendingPathComponent(localBook.fileName)
            try contents.write(to: destination, options: .atomic)
            if let index = books.firstIndex(where: { $0.id == localBook.id }) {
                books[index] = localBook
            } else {
                books.append(localBook)
            }
            deletedBooks.removeAll { $0.bookID == localBook.id }
            save()
        } catch {
            alertMessage = "CloudReader couldn't download a synced book. Check the available storage on this device."
        }
    }

    func applySyncedDeletion(_ deletion: BookDeletion) {
        if let book = books.first(where: { $0.id == deletion.bookID }), book.modifiedAt <= deletion.deletedAt {
            if let url = fileURL(for: book) { try? fileManager.removeItem(at: url) }
            books.removeAll { $0.id == deletion.bookID }
        }
        if let index = deletedBooks.firstIndex(where: { $0.bookID == deletion.bookID }) {
            if deletedBooks[index].deletedAt < deletion.deletedAt { deletedBooks[index] = deletion }
        } else {
            deletedBooks.append(deletion)
        }
        save()
    }

    func saveAIConversation(_ conversation: AIConversationRecord) {
        guard !conversation.messages.isEmpty else { return }
        var saved = conversation
        if let existing = aiConversations.first(where: { $0.id == saved.id }) {
            saved.createdAt = existing.createdAt
        }
        saved.modifiedAt = .now
        if let firstQuestion = saved.messages.first(where: { $0.role == .user })?.text {
            saved.title = AIConversationRecord.suggestedTitle(for: firstQuestion)
        }
        if let index = aiConversations.firstIndex(where: { $0.id == saved.id }) {
            aiConversations[index] = saved
        } else {
            aiConversations.append(saved)
        }
        deletedAIConversations.removeAll { $0.conversationID == saved.id }
        save()
    }

    func removeAIConversation(_ conversation: AIConversationRecord) {
        aiConversations.removeAll { $0.id == conversation.id }
        deletedAIConversations.removeAll { $0.conversationID == conversation.id }
        deletedAIConversations.append(AIConversationDeletion(conversationID: conversation.id, deletedAt: .now))
        save()
    }

    func applySyncedAIConversation(_ conversation: AIConversationRecord) {
        var merged = conversation
        if let local = aiConversations.first(where: { $0.id == conversation.id }) {
            merged = local.merging(conversation)
            if local == merged { return }
        }
        if let deletion = deletedAIConversations.first(where: { $0.conversationID == merged.id }), deletion.deletedAt >= merged.modifiedAt {
            return
        }
        if let index = aiConversations.firstIndex(where: { $0.id == merged.id }) {
            aiConversations[index] = merged
        } else {
            aiConversations.append(merged)
        }
        deletedAIConversations.removeAll { $0.conversationID == merged.id && $0.deletedAt < merged.modifiedAt }
        save()
    }

    func applySyncedAIConversationDeletion(_ deletion: AIConversationDeletion) {
        if let conversation = aiConversations.first(where: { $0.id == deletion.conversationID }), conversation.modifiedAt <= deletion.deletedAt {
            aiConversations.removeAll { $0.id == deletion.conversationID }
        }
        if let index = deletedAIConversations.firstIndex(where: { $0.conversationID == deletion.conversationID }) {
            if deletedAIConversations[index].deletedAt < deletion.deletedAt { deletedAIConversations[index] = deletion }
        } else {
            deletedAIConversations.append(deletion)
        }
        save()
    }

    private func update(_ id: UUID, change: (inout Book) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
        books[index].modifiedAt = .now
        save()
    }

    private func load() {
        if let url = try? indexURL(),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            books = decoded.filter { fileURL(for: $0) != nil }
        }
        if let url = try? deletionsURL(), let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([BookDeletion].self, from: data) {
            deletedBooks = decoded
        }
        if let url = try? aiConversationsURL(), let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([AIConversationRecord].self, from: data) {
            aiConversations = decoded
        }
        if let url = try? aiConversationDeletionsURL(), let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([AIConversationDeletion].self, from: data) {
            deletedAIConversations = decoded
        }
    }

    private func save() {
        do {
            let url = try indexURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(books).write(to: url, options: .atomic)
            try encoder.encode(deletedBooks).write(to: deletionsURL(), options: .atomic)
            try encoder.encode(aiConversations).write(to: aiConversationsURL(), options: .atomic)
            try encoder.encode(deletedAIConversations).write(to: aiConversationDeletionsURL(), options: .atomic)
        } catch {
            alertMessage = "CloudReader couldn't save your library. Check the available storage on this device."
        }
    }

    private func indexURL() throws -> URL {
        let root = try applicationSupportDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("library.json")
    }

    private func deletionsURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("deletions.json")
    }

    private func aiConversationsURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("ai-conversations.json")
    }

    private func aiConversationDeletionsURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("ai-conversation-deletions.json")
    }

    private func booksDirectory() throws -> URL {
        let directory = try applicationSupportDirectory().appendingPathComponent("Books", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func applicationSupportDirectory() throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func descriptionSource(at url: URL, format: BookFormat) -> String? {
        switch format {
        case .txt:
            return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16))
        case .pdf:
            guard let document = PDFDocument(url: url) else { return nil }
            return (0..<min(document.pageCount, 3))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
        case .epub, .mobi, .azw3, .fb2, .cbz, .cbr:
            return nil
        }
    }

    private static func inferredBriefDescription(from source: String?, title: String) -> String? {
        guard let source else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard line.count > 28, line.lowercased() != normalizedTitle else { return false }
                let lowered = line.lowercased()
                return !lowered.hasPrefix("chapter ")
                    && !lowered.hasPrefix("copyright")
                    && !lowered.hasPrefix("isbn")
                    && !lowered.hasPrefix("all rights reserved")
            }
        guard !lines.isEmpty else { return nil }

        let opening = lines.prefix(8).joined(separator: " ")
        let limit = 360
        guard opening.count > limit else { return opening }
        let prefix = String(opening.prefix(limit))
        if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > 250 {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && URL(fileURLWithPath: name).lastPathComponent == name
    }
}

struct AIConversationHistoryView: View {
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.dismiss) private var dismiss

    let onSelect: (AIConversationRecord) -> Void

    private var conversations: [AIConversationRecord] {
        library.aiConversations.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No saved conversations",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Your AI conversations will appear here after you ask your first question.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(conversations) { conversation in
                        HStack(spacing: 12) {
                            Button {
                                onSelect(conversation)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(conversation.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: 8) {
                                        if let bookTitle = conversation.bookTitle {
                                            Label(bookTitle, systemImage: "book.closed")
                                                .lineLimit(1)
                                        }
                                        Text(conversation.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                            .lineLimit(1)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if let message = conversation.messages.last {
                                        Text(message.text)
                                            .font(.system(size: 12, design: .serif))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                library.removeAIConversation(conversation)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 38, height: 38)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(conversation.title)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("AI History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
