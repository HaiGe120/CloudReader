import CloudReaderCore
import SwiftUI

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
