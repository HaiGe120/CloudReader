import CloudReaderCore
import Foundation
import Observation
import SwiftUI

/// The launch context belongs to the open reader. A saved session supplies its
/// transcript and sharing choice, even when the reader has since turned a page.
@MainActor @Observable
final class ReaderChatSession {
    let launchContext: AIConversationRecord
    private(set) var record: AIConversationRecord
    var includeBookContext: Bool
    var draft: String
    var errorMessage: String?
    private(set) var isThinking = false
    private var didOpen = false

    init(bookID: UUID?, bookTitle: String?, bookDescription: String?, bookContext: String?,
         selectedText: String?, contextDescription: String?, initialQuestion: String = "") {
        let context = AIConversationRecord(bookID: bookID, bookTitle: bookTitle,
            bookDescription: bookDescription, selectedText: selectedText, bookContext: bookContext,
            contextDescription: contextDescription,
            includeBookContext: [bookTitle, selectedText, bookContext, bookDescription].contains { $0 != nil })
        launchContext = context
        record = context
        includeBookContext = context.includeBookContext
        draft = initialQuestion
    }

    var context: AIConversationRecord { launchContext.bookID == nil ? record : launchContext }

    var shareText: String {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = question.isEmpty ? record.messages.last(where: { $0.role == .user })?.text ?? "" : question
        guard includeBookContext else { return prompt }

        var sections: [String] = []
        if let bookTitle = context.bookTitle, !bookTitle.isEmpty { sections.append("Book: \(bookTitle)") }
        if let bookDescription = context.bookDescription, !bookDescription.isEmpty { sections.append("Brief description: \(bookDescription)") }
        if let selectedText = context.selectedText, !selectedText.isEmpty { sections.append("Selected passage:\n\(selectedText)") }
        if let bookContext = context.bookContext, !bookContext.isEmpty { sections.append("Book text:\n\(bookContext)") }
        if !prompt.isEmpty { sections.append("Question:\n\(prompt)") }
        return sections.joined(separator: "\n\n")
    }

    func open(in library: BookLibrary) {
        guard !didOpen else { return }
        didOpen = true
        if let bookID = launchContext.bookID,
           let latest = library.conversations(for: bookID).first {
            restore(latest)
        }
    }

    func restore(_ saved: AIConversationRecord) {
        guard !isThinking, launchContext.bookID == nil || saved.bookID == launchContext.bookID else { return }
        record = saved
        includeBookContext = saved.includeBookContext
        draft = ""
    }

    func startNew() {
        guard !isThinking else { return }
        record = launchContext
        record.id = UUID()
        record.createdAt = .now
        includeBookContext = launchContext.includeBookContext
        draft = ""
    }

    func refresh(from records: [AIConversationRecord]) {
        guard !record.messages.isEmpty else { return }
        if let saved = records.first(where: { $0.id == record.id }) {
            record.messages = saved.messages
        } else if !isThinking {
            startNew()
        }
    }

    static func answer(_ turn: AIConversationRecord) async throws -> String {
        try await AIService.ask(messages: turn.messages,
            bookTitle: turn.includeBookContext ? turn.bookTitle : nil,
            bookDescription: turn.bookDescription, selectedText: turn.selectedText, bookContext: turn.bookContext)
    }

    func send(in library: BookLibrary, reply: (AIConversationRecord) async throws -> String = ReaderChatSession.answer) async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        let source = context
        var turn = record
        if !turn.messages.isEmpty {
            guard let latest = library.aiConversations.first(where: { $0.id == turn.id }) else {
                errorMessage = "This conversation was deleted. Start a new conversation to send your question."
                return
            }
            turn.messages = latest.messages
        }
        turn.bookTitle = source.bookTitle
        turn.includeBookContext = includeBookContext
        turn.bookDescription = includeBookContext ? source.bookDescription : nil
        turn.selectedText = includeBookContext ? source.selectedText : nil
        turn.bookContext = includeBookContext ? source.bookContext : nil
        turn.contextDescription = includeBookContext ? source.contextDescription : nil
        turn.messages.append(.user(question))
        record.messages = turn.messages
        library.saveAIConversation(turn)
        draft = ""
        isThinking = true
        defer {
            isThinking = false
            refresh(from: library.aiConversations)
        }
        do {
            let answer = try await reply(turn)
            // Use the current stored copy so an intervening sync or another
            // window's turn survives. A deleted session stays deleted.
            guard var latest = library.aiConversations.first(where: { $0.id == turn.id }) else { return }
            latest.messages.append(.assistant(answer))
            library.saveAIConversation(latest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension BookLibrary {
    func conversations(for bookID: UUID?) -> [AIConversationRecord] {
        aiConversations.filter { bookID == nil || $0.bookID == bookID }
            .sorted {
                if $0.modifiedAt == $1.modifiedAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.modifiedAt > $1.modifiedAt
            }
    }
}

private struct ReaderChatReplyKey: EnvironmentKey {
    static let defaultValue: @MainActor (AIConversationRecord) async throws -> String = ReaderChatSession.answer
}

extension EnvironmentValues {
    var readerChatReply: @MainActor (AIConversationRecord) async throws -> String {
        get { self[ReaderChatReplyKey.self] }
        set { self[ReaderChatReplyKey.self] = newValue }
    }
}
