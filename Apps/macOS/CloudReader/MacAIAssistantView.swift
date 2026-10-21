import SwiftUI
import CloudReaderCore

struct MacAIAssistantView: View {
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
    @State private var profile = AIProfileStore.load()
    @FocusState private var isPromptFocused: Bool

    @State private var bookID: UUID?
    @State private var bookTitle: String?
    @State private var bookContext: String?
    @State private var bookDescription: String?
    @State private var selectedText: String?
    @State private var contextDescription: String?

    init(
        bookID: UUID? = nil,
        bookTitle: String?,
        bookContext: String?,
        bookDescription: String? = nil,
        selectedText: String? = nil,
        contextDescription: String? = nil
    ) {
        _bookID = State(initialValue: bookID)
        _bookTitle = State(initialValue: bookTitle)
        _bookContext = State(initialValue: bookContext)
        _bookDescription = State(initialValue: bookDescription)
        _selectedText = State(initialValue: selectedText)
        _contextDescription = State(initialValue: contextDescription)
        _includeBookContext = State(initialValue: bookContext != nil || selectedText != nil)
    }

    private var remoteAIIsConfigured: Bool {
        !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AIProfileStore.hasAPIKey
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.48, green: 0.38, blue: 0.28))
                    .frame(width: 46, height: 46)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bookTitle.map { "Ask about \($0)" } ?? "Ask CloudReader")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                    Text(profile.modelSource == .appleOnDevice
                         ? "Apple Intelligence · processed on this Mac"
                         : "\(profile.name) · \(profile.endpointKind.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("New conversation", systemImage: "square.and.pencil", action: startNewConversation)
                    Button("Conversation history (\(library.aiConversations.count))", systemImage: "clock.arrow.circlepath") {
                        isShowingHistory = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Conversation options")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let selectedText, !selectedText.isEmpty {
                Toggle(isOn: $includeBookContext) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include the selected passage")
                            .font(.callout.weight(.medium))
                        Text("The passage is sent with your question as context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(13)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            } else if let bookContext {
                Toggle(isOn: $includeBookContext) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include text from \(bookTitle ?? "this book")")
                            .font(.callout.weight(.medium))
                        Text("Up to \(min(bookContext.count, profile.modelSource == .appleOnDevice ? AIService.onDeviceContextCharacterLimit : bookContext.count).formatted()) characters are included in this question.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(13)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            }

            if profile.modelSource == .remoteAPI && !remoteAIIsConfigured {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set up AI to ask a question")
                            .font(.callout.weight(.medium))
                        Text("Choose a model and add its API key in Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    SettingsLink {
                        Label("Settings", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            }

            if conversation.isEmpty {
                ContentUnavailableView {
                    Label("What would you like to explore?", systemImage: "text.book.closed")
                } description: {
                    Text("Ask a question about your reading or start with any topic.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 15) {
                            ForEach(conversation) { message in
                                HStack(alignment: .top) {
                                    if message.role == .user { Spacer(minLength: 100) }
                                    Text(message.text)
                                        .font(.system(size: 15, design: .serif))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 12)
                                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                                        .background(
                                            message.role == .user
                                                ? Color(red: 0.35, green: 0.42, blue: 0.37)
                                                : Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 17)
                                        )
                                    if message.role == .assistant { Spacer(minLength: 100) }
                                }
                                .id(message.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: conversation.count) { _, _ in
                        if let latest = conversation.last { proxy.scrollTo(latest.id, anchor: .bottom) }
                    }
                }
            }

            if isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking with \(profile.assistantName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField(selectedText == nil ? "Ask a question…" : "Ask about this passage…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .onSubmit(sendQuestion)
                    .focused($isPromptFocused)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary))
                Button(action: sendQuestion) {
                    Label("Ask", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }

            Text(profile.modelSource == .appleOnDevice
                 ? AIService.onDeviceAvailabilityDescription + " Saved conversation and included book context sync to your selected cloud drive when connected."
                 : "Your API key stays in Keychain. Saved conversation and included book context sync to your selected cloud drive when connected.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { isPromptFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            profile = AIProfileStore.load()
        }
        .sheet(isPresented: $isShowingHistory) {
            AIConversationHistoryView(onSelect: restoreConversation)
                .environmentObject(library)
                .frame(minWidth: 540, minHeight: 420)
        }
        .alert("AI assistant", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func sendQuestion() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        guard profile.modelSource != .remoteAPI || remoteAIIsConfigured else {
            errorMessage = AIServiceError.notConfigured.localizedDescription
            return
        }
        draft = ""
        conversation.append(.user(question))
        persistConversation()
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let answer = try await AIService.ask(
                    messages: conversation,
                    bookTitle: bookTitle,
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
