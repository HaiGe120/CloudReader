import CloudReaderCore
import SwiftUI

struct AIModelPicker: View {
    @Binding var profile: AIProviderConfiguration
    let enteredKey: String
    @State private var browsing = false

    var body: some View {
        Button { browsing = true } label: { Label("Browse models", systemImage: "list.bullet") }
            .accessibilityIdentifier("ai.browseModels")
            .sheet(isPresented: $browsing) {
                AIModelList(profile: profile, enteredKey: enteredKey) { profile.model = $0 }
            }
        TextField("Model ID, e.g. \(profile.endpointKind.placeholderModel)", text: $profile.model)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #else
            .textFieldStyle(.roundedBorder)
            #endif
            .accessibilityIdentifier("ai.modelID")
    }
}

private struct AIModelList: View {
    let profile: AIProviderConfiguration
    let enteredKey: String
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [RemoteAIModel]?
    @State private var failure: String?
    @State private var search = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView {
                        Label("Couldn’t load models", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { reload += 1 }
                    }
                } else if let models {
                    if models.isEmpty {
                        ContentUnavailableView("No models returned", systemImage: "list.bullet",
                            description: Text("You can enter a model ID in Settings."))
                    } else {
                        let matches = models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
                        List(matches) { model in
                            Button {
                                select(model.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(model.title)
                                        if model.title != model.id { Text(model.id).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if model.id == profile.model { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ai.remoteModel.\(model.id)")
                        }
                        .overlay { if matches.isEmpty { ContentUnavailableView.search(text: search) } }
                        .searchable(text: $search, prompt: "Search models")
                    }
                } else {
                    ProgressView("Fetching models…")
                }
            }
            .navigationTitle("Choose a model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { reload += 1 }
                        .disabled(models == nil && failure == nil)
                }
            }
            .task(id: reload) {
                models = nil
                failure = nil
                do {
                    let fetched = try await AIModelCatalog.fetch(profile: profile, enteredKey: enteredKey)
                    try Task.checkCancellation()
                    models = fetched
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}
