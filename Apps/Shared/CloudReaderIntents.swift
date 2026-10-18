import AppIntents
import Foundation

struct AskCloudReaderIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask CloudReader"
    static var description = IntentDescription("Ask a question using CloudReader's selected AI provider, including Apple Intelligence when available.")
    static var openAppWhenRun = false

    @Parameter(title: "Question", description: "Ask a question. CloudReader uses your selected AI provider.")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let userMessage = AIConversationMessage.user(question)
        let answer = try await AIService.ask(messages: [userMessage])
        let assistantMessage = AIConversationMessage.assistant(answer)
        let conversation = AIConversationRecord(
            title: AIConversationRecord.suggestedTitle(for: question),
            messages: [userMessage, assistantMessage],
            createdAt: userMessage.createdAt,
            modifiedAt: assistantMessage.createdAt
        )
        await MainActor.run {
            BookLibrary.shared.saveAIConversation(conversation)
        }
        let spokenAnswer = String(answer.prefix(500))
        return .result(value: answer, dialog: IntentDialog(stringLiteral: spokenAnswer))
    }
}

#if os(iOS)
struct CloudReaderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCloudReaderIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask a question with \(.applicationName)"
            ],
            shortTitle: "Ask CloudReader",
            systemImageName: "sparkles"
        )
    }
}
#endif
