import SwiftUI
import CloudReaderCore

struct AIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.readerChatReply) private var reply
    @State private var chat: ReaderChatSession
    @State private var isShowingHistory = false
    @FocusState private var isComposerFocused: Bool

    init(
        bookID: UUID? = nil,
        bookTitle: String?,
        bookContext: String?,
        initialQuestion: String = "",
        bookDescription: String? = nil,
        selectedText: String? = nil,
        contextDescription: String? = nil
    ) {
        _chat = State(initialValue: ReaderChatSession(bookID: bookID, bookTitle: bookTitle,
            bookDescription: bookDescription, bookContext: bookContext, selectedText: selectedText,
            contextDescription: contextDescription, initialQuestion: initialQuestion))
    }

    private var profile: AIProviderConfiguration { AIProfileStore.load() }

    private var hasReaderContext: Bool {
        chat.context.bookTitle != nil || chat.context.bookDescription != nil || chat.context.selectedText != nil || chat.context.bookContext != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if hasReaderContext && !isComposerFocused {
                    contextDisclosure
                }

                if chat.record.messages.isEmpty {
                    ScrollView { welcome }
                } else {
                    conversationList
                }

                if chat.isThinking {
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
            .navigationTitle(chat.context.bookTitle.map { "Ask about \($0)" } ?? "Ask anything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: chat.shareText.isEmpty ? "A question for my AI assistant" : chat.shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share question with another app")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New conversation", systemImage: "square.and.pencil", action: chat.startNew)
                        Button("Conversation history (\(library.conversations(for: chat.launchContext.bookID).count))", systemImage: "clock.arrow.circlepath") {
                            isShowingHistory = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                    .disabled(chat.isThinking)
                }
            }
            .onAppear { chat.open(in: library) }
            .onChange(of: library.aiConversations) { _, records in chat.refresh(from: records) }
            .sheet(isPresented: $isShowingHistory) {
                AIConversationHistoryView(bookID: chat.launchContext.bookID, onSelect: chat.restore)
                    .environmentObject(library)
            }
            .scrollDismissesKeyboard(.interactively)
            .alert("AI assistant", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { chat.errorMessage = nil }
            } message: {
                Text(chat.errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { chat.errorMessage != nil }, set: { if !$0 { chat.errorMessage = nil } })
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color(red: 0.50, green: 0.39, blue: 0.27))
                .frame(width: 54, height: 54)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(chat.context.selectedText != nil ? "Your highlighted passage is ready." : chat.context.bookTitle == nil ? "A thought on your mind?" : "Read with a curious mind.")
                .font(.system(size: 27, weight: .bold, design: .serif))
            Text(chat.context.bookTitle == nil
                 ? "Ask a general question, or open a book and ask about its text."
                 : chat.context.selectedText != nil
                    ? "The book title, brief description, and selected text are ready as context. Write the question you want to ask."
                    : "Ask about this book, explore an idea, or start a completely different question.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            if let bookTitle = chat.context.bookTitle {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed")
                    Text(bookTitle).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                if chat.context.bookContext == nil && chat.context.selectedText == nil {
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
            Toggle(contextToggleTitle, isOn: $chat.includeBookContext)
                .font(.system(size: 13, weight: .medium))
            if chat.includeBookContext {
                if let bookTitle = chat.context.bookTitle, !bookTitle.isEmpty {
                    contextRow(title: "BOOK", value: bookTitle)
                }
                if let bookDescription = chat.context.bookDescription, !bookDescription.isEmpty {
                    contextRow(title: "BRIEF DESCRIPTION", value: bookDescription)
                }
                if let selectedText = chat.context.selectedText, !selectedText.isEmpty {
                    let preview = String(selectedText.prefix(280))
                    contextRow(title: "HIGHLIGHTED TEXT", value: preview + (selectedText.count > 280 ? "…" : ""))
                }
                if let bookContext = chat.context.bookContext, !bookContext.isEmpty {
                    let includedCount = profile.modelSource == .appleOnDevice
                        ? min(bookContext.count, AIService.onDeviceContextCharacterLimit)
                        : bookContext.count
                    Text(chat.context.contextDescription ?? "Includes up to \(includedCount.formatted()) characters of book text.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let contextDescription = chat.context.contextDescription {
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
        if chat.context.selectedText != nil { return "Include book details and highlighted text" }
        if chat.context.bookContext != nil { return "Include book details and book text" }
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
                    ForEach(chat.record.messages) { message in
                        AIMessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: chat.record.messages.count) {
                guard let latest = chat.record.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(latest.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 11) {
                TextField(chat.context.selectedText == nil ? "Ask a question…" : "What would you like to ask?", text: $chat.draft)
                    .font(.system(size: 16))
                    .accessibilityIdentifier("assistant.question")
                    .focused($isComposerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendQuestion)
                    .padding(.vertical, 10)

                if isComposerFocused {
                    Button { isComposerFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(minWidth: 36, minHeight: 40)
                    }
                    .accessibilityLabel("Hide keyboard")
                }

                Button(action: sendQuestion) {
                    Image(systemName: chat.isThinking ? "hourglass" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color(red: 0.35, green: 0.42, blue: 0.37), in: Circle())
                }
                .disabled(chat.isThinking || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(chat.isThinking || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
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
        isComposerFocused = false
        Task { await chat.send(in: library, reply: reply) }
    }
}

private struct AIMessageBubble: View {
    let message: AIConversationMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 45) }
            AssistantMessageText(message: message)
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
