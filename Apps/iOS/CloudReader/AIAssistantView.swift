import SwiftUI
import CloudReaderCore

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibrary
    @State private var conversation: [AIConversationMessage] = []
    @State private var conversationID = UUID()
    @State private var conversationCreatedAt = Date.now
    @State private var draft = ""
    @State private var isThinking = false
    @State private var includeBookContext: Bool
    @State private var errorMessage: String?
    @State private var isShowingHistory = false
    @FocusState private var isComposerFocused: Bool

    @State private var bookID: UUID?
    @State private var bookTitle: String?
    @State private var bookContext: String?
    let initialQuestion: String
    @State private var bookDescription: String?
    @State private var selectedText: String?
    @State private var contextDescription: String?

    init(
        bookID: UUID? = nil,
        bookTitle: String?,
        bookContext: String?,
        initialQuestion: String = "",
        bookDescription: String? = nil,
        selectedText: String? = nil,
        contextDescription: String? = nil
    ) {
        _bookID = State(initialValue: bookID)
        _bookTitle = State(initialValue: bookTitle)
        _bookContext = State(initialValue: bookContext)
        self.initialQuestion = initialQuestion
        _bookDescription = State(initialValue: bookDescription)
        _selectedText = State(initialValue: selectedText)
        _contextDescription = State(initialValue: contextDescription)
        _draft = State(initialValue: initialQuestion)
        _includeBookContext = State(initialValue: bookTitle != nil || bookDescription != nil || selectedText != nil || bookContext != nil)
    }

    private var profile: AIProviderConfiguration { AIProfileStore.load() }

    private var shareText: String {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = question.isEmpty ? conversation.last(where: { $0.role == .user })?.text ?? "" : question
        guard includeBookContext else { return prompt }

        var sections: [String] = []
        if let bookTitle, !bookTitle.isEmpty { sections.append("Book: \(bookTitle)") }
        if let bookDescription, !bookDescription.isEmpty { sections.append("Brief description: \(bookDescription)") }
        if let selectedText, !selectedText.isEmpty { sections.append("Selected passage:\n\(selectedText)") }
        if let bookContext, !bookContext.isEmpty { sections.append("Book text:\n\(bookContext)") }
        if !prompt.isEmpty { sections.append("Question:\n\(prompt)") }
        return sections.joined(separator: "\n\n")
    }

    private var hasReaderContext: Bool {
        bookTitle != nil || bookDescription != nil || selectedText != nil || bookContext != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if hasReaderContext {
                    contextDisclosure
                }

                if conversation.isEmpty {
                    welcome
                } else {
                    conversationList
                }

                if isThinking {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Thinking with \(profile.assistantName)…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 5)
                }

                composer
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(bookTitle.map { "Ask about \($0)" } ?? "Ask anything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText.isEmpty ? "A question for my AI assistant" : shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share question with another app")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New conversation", systemImage: "square.and.pencil", action: startNewConversation)
                        Button("Conversation history (\(library.aiConversations.count))", systemImage: "clock.arrow.circlepath") {
                            isShowingHistory = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                }
            }
            .sheet(isPresented: $isShowingHistory) {
                AIConversationHistoryView(onSelect: restoreConversation)
                    .environmentObject(library)
            }
            .scrollDismissesKeyboard(.interactively)
            .alert("AI assistant", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color(red: 0.50, green: 0.39, blue: 0.27))
                .frame(width: 54, height: 54)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(selectedText != nil ? "Your highlighted passage is ready." : bookTitle == nil ? "A thought on your mind?" : "Read with a curious mind.")
                .font(.system(size: 27, weight: .bold, design: .serif))
            Text(bookTitle == nil
                 ? "Ask a general question, or open a book and ask about its text."
                 : selectedText != nil
                    ? "The book title, brief description, and selected text are ready as context. Write the question you want to ask."
                    : "Ask about this book, explore an idea, or start a completely different question.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            if let bookTitle {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed")
                    Text(bookTitle).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                if bookContext == nil && selectedText == nil {
                    Text("This format does not provide extractable text yet. You can still ask general questions or quote a passage in your prompt.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if profile.modelSource == .remoteAPI && !AIProfileStore.hasAPIKey {
                Label("Add your AI endpoint and API key in Settings to begin.", systemImage: "key.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.42), lineWidth: 1)
        }
    }

    private var contextDisclosure: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(contextToggleTitle, isOn: $includeBookContext)
                .font(.system(size: 13, weight: .medium))
            if includeBookContext {
                if let bookTitle, !bookTitle.isEmpty {
                    contextRow(title: "BOOK", value: bookTitle)
                }
                if let bookDescription, !bookDescription.isEmpty {
                    contextRow(title: "BRIEF DESCRIPTION", value: bookDescription)
                }
                if let selectedText, !selectedText.isEmpty {
                    let preview = String(selectedText.prefix(280))
                    contextRow(title: "HIGHLIGHTED TEXT", value: preview + (selectedText.count > 280 ? "…" : ""))
                }
                if let bookContext, !bookContext.isEmpty {
                    let includedCount = profile.modelSource == .appleOnDevice
                        ? min(bookContext.count, AIService.onDeviceContextCharacterLimit)
                        : bookContext.count
                    Text(contextDescription ?? "The first \(includedCount.formatted()) characters of book text will be included.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let contextDescription {
                    Text(contextDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var contextToggleTitle: String {
        if selectedText != nil { return "Include book details and highlighted text" }
        if bookContext != nil { return "Include book details and book text" }
        return "Include book details in my request"
    }

    private func contextRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(conversation) { message in
                        AIMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: conversation.count) {
                guard let latest = conversation.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(latest.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 11) {
                TextField(selectedText == nil ? "Ask a question…" : "What would you like to ask?", text: $draft, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendQuestion)
                    .padding(.vertical, 10)

                Button(action: sendQuestion) {
                    Image(systemName: isThinking ? "hourglass" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color(red: 0.35, green: 0.42, blue: 0.37), in: Circle())
                }
                .disabled(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("Send question")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.modelSource == .appleOnDevice
                     ? "Processed on this device · Apple Intelligence"
                     : "Sent to \(profile.name) · \(profile.endpointKind.title)")
                Text(profile.modelSource == .appleOnDevice
                     ? "AI runs on this device. Saved conversation and included book context sync to your selected cloud drive when connected."
                     : "Your API key stays in Keychain. Saved conversation and included book context sync to your selected cloud drive when connected.")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
        }
    }

    private func sendQuestion() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        draft = ""
        conversation.append(.user(question))
        persistConversation()
        isComposerFocused = false
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let answer = try await AIService.ask(
                    messages: conversation,
                    bookTitle: includeBookContext ? bookTitle : nil,
                    bookDescription: includeBookContext ? bookDescription : nil,
                    selectedText: includeBookContext ? selectedText : nil,
                    bookContext: includeBookContext ? bookContext : nil
                )
                conversation.append(.assistant(answer))
                persistConversation()
            } catch {
                persistConversation()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func persistConversation() {
        guard !conversation.isEmpty else { return }
        var record = AIConversationRecord(
            id: conversationID,
            messages: conversation,
            bookID: bookID,
            bookTitle: bookTitle,
            bookDescription: includeBookContext ? bookDescription : nil,
            selectedText: includeBookContext ? selectedText : nil,
            bookContext: includeBookContext ? bookContext : nil,
            contextDescription: includeBookContext ? contextDescription : nil,
            includeBookContext: includeBookContext,
            createdAt: conversationCreatedAt,
            modifiedAt: .now
        )
        if let firstQuestion = conversation.first(where: { $0.role == .user })?.text {
            record.title = AIConversationRecord.suggestedTitle(for: firstQuestion)
        }
        library.saveAIConversation(record)
    }

    private func restoreConversation(_ record: AIConversationRecord) {
        conversationID = record.id
        conversationCreatedAt = record.createdAt
        conversation = record.messages
        bookID = record.bookID
        bookTitle = record.bookTitle
        bookDescription = record.bookDescription
        selectedText = record.selectedText
        bookContext = record.bookContext
        contextDescription = record.contextDescription
        includeBookContext = record.includeBookContext
        draft = ""
    }

    private func startNewConversation() {
        conversationID = UUID()
        conversationCreatedAt = .now
        conversation = []
        draft = ""
        bookID = nil
        bookTitle = nil
        bookDescription = nil
        selectedText = nil
        bookContext = nil
        contextDescription = nil
        includeBookContext = false
    }
}

private struct AIMessageBubble: View {
    let message: AIConversationMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 45) }
            Text(message.text)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .foregroundStyle(isUser ? .white : .primary)
                .background(isUser ? Color(red: 0.34, green: 0.40, blue: 0.36) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if !isUser { Spacer(minLength: 45) }
        }
        .frame(maxWidth: .infinity)
    }
}
