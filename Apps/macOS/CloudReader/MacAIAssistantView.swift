import SwiftUI
import CloudReaderCore

struct MacAIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibrary
    @Environment(\.readerChatReply) private var reply
    @State private var chat: ReaderChatSession
    @State private var isShowingHistory = false
    @State private var profile = AIProfileStore.load()
    @FocusState private var isPromptFocused: Bool

    init(
        bookID: UUID? = nil,
        bookTitle: String?,
        bookContext: String?,
        bookDescription: String? = nil,
        selectedText: String? = nil,
        contextDescription: String? = nil
    ) {
        _chat = State(initialValue: ReaderChatSession(bookID: bookID, bookTitle: bookTitle,
            bookDescription: bookDescription, bookContext: bookContext, selectedText: selectedText,
            contextDescription: contextDescription))
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
                    Text(chat.context.bookTitle.map { "Ask about \($0)" } ?? "Ask CloudReader")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                    Text(profile.modelSource == .appleOnDevice
                         ? "Apple Intelligence · processed on this Mac"
                         : "\(profile.name) · \(profile.endpointKind.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: chat.shareText.isEmpty ? "A question for my AI assistant" : chat.shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share question with another app")
                Menu {
                    Button("New conversation", systemImage: "square.and.pencil", action: chat.startNew)
                    Button("Conversation history (\(library.conversations(for: chat.launchContext.bookID).count))", systemImage: "clock.arrow.circlepath") {
                        isShowingHistory = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Conversation options")
                .disabled(chat.isThinking)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if chat.context.bookTitle != nil || chat.context.bookContext != nil || chat.context.selectedText != nil {
                Toggle(isOn: $chat.includeBookContext) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include book details and reading context").font(.callout.weight(.medium))
                        if chat.includeBookContext, let description = chat.context.bookDescription {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if chat.includeBookContext, let excerpt = chat.context.selectedText {
                            Text(String(excerpt.prefix(280))).font(.caption).lineLimit(2)
                        }
                        Text(chat.context.contextDescription ?? "Includes available book details and highlighted text.")
                            .font(.caption).foregroundStyle(.secondary)
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

            if chat.record.messages.isEmpty {
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
                            ForEach(chat.record.messages) { message in
                                HStack(alignment: .top) {
                                    if message.role == .user { Spacer(minLength: 100) }
                                    AssistantMessageText(message: message)
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
                    .onChange(of: chat.record.messages.count) { _, _ in
                        if let latest = chat.record.messages.last { proxy.scrollTo(latest.id, anchor: .bottom) }
                    }
                }
            }

            if chat.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking with \(profile.assistantName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField(chat.context.selectedText == nil ? "Ask a question…" : "Ask about this passage…", text: $chat.draft)
                    .accessibilityIdentifier("assistant.question")
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
                .disabled(chat.isThinking || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .onAppear { chat.open(in: library) }
        .onChange(of: library.aiConversations) { _, records in chat.refresh(from: records) }
        .sheet(isPresented: $isShowingHistory) {
            AIConversationHistoryView(bookID: chat.launchContext.bookID, onSelect: chat.restore)
                .environmentObject(library)
                .frame(minWidth: 540, minHeight: 420)
        }
        .alert("AI assistant", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { chat.errorMessage = nil }
        } message: {
            Text(chat.errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { chat.errorMessage != nil }, set: { if !$0 { chat.errorMessage = nil } })
    }

    private func sendQuestion() {
        Task { await chat.send(in: library, reply: reply) }
    }
}
