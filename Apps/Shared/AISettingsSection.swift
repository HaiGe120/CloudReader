import SwiftUI
import CloudReaderCore

struct AISettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = AIProfileStore.load()
    @State private var lastLoaded = AIProfileStore.load()
    @State private var enteredKey = ""
    @State private var hasKey = AIProfileStore.hasAPIKey
    @State private var syncEnabled = AIProfileStore.syncEnabled
    @State private var message: String?

    private var hasDraft: Bool { profile != lastLoaded || !enteredKey.isEmpty }

    var body: some View {
        Section {
            Picker("AI provider", selection: $profile.modelSource) {
                ForEach(AIModelSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            if profile.modelSource == .remoteAPI {
                TextField("Profile name", text: $profile.name)
                Picker("API format", selection: $profile.endpointKind) {
                    ForEach(AIEndpointKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                TextField("API endpoint or /v1 base URL (optional)", text: $profile.endpointURL)
                    .accessibilityIdentifier("ai.endpointURL")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField(hasKey ? "Replace saved API key (optional)" : "API key", text: $enteredKey)
                    .accessibilityIdentifier("ai.apiKey")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                AIModelPicker(profile: $profile, enteredKey: enteredKey)
                Toggle("Allow web search", isOn: $profile.webSearchEnabled)
                if profile.webSearchEnabled {
                    Text(profile.endpointKind == .openAIChatCompletions
                         ? "Choose a search-capable Chat Completions model. Provider search charges may apply."
                         : "Your provider may charge for searches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Use Apple Intelligence when offline", isOn: $profile.useAppleWhenOffline)
            }
            if profile.modelSource == .appleOnDevice || profile.useAppleWhenOffline {
                Label(AIService.onDeviceAvailabilityDescription, systemImage: "cpu")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Save AI settings") {
                do {
                    try AIProfileStore.save(profile, apiKey: enteredKey)
                    refresh()
                    message = "AI settings saved."
                } catch { message = error.localizedDescription }
            }
            if hasKey {
                Button(syncEnabled ? "Remove API key from synced devices" : "Remove saved API key", role: .destructive) {
                    do {
                        try AIProfileStore.removeAPIKey()
                        enteredKey = ""
                        hasKey = false
                        message = "Saved API key removed."
                    } catch { message = error.localizedDescription }
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("AI assistant")
        } footer: {
            Text("Chat and the Ask CloudReader shortcut use this provider. The offline option uses Apple Intelligence when available and returns to your remote model when you reconnect.")
        }

        Section {
            Toggle("Sync AI settings and API key", isOn: Binding(get: { syncEnabled }, set: { enabled in
                do {
                    try AIProfileStore.setSyncEnabled(enabled)
                    refresh()
                    message = nil
                } catch { message = error.localizedDescription }
            }))
            .disabled(hasDraft)
            if hasDraft { Text("Save your changes before switching sync.").font(.caption) }
        } header: {
            Text("iCloud Keychain")
        } footer: {
            Text("Turn on Passwords & Keychain in iCloud settings and enable this switch on each Apple device. Your provider, model, options, and API key sync together. Library storage connections are configured separately.")
        }
        .onAppear { if !hasDraft { refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !hasDraft { refresh() }
        }
    }

    private func refresh() {
        profile = AIProfileStore.load()
        lastLoaded = profile
        enteredKey = ""
        hasKey = AIProfileStore.hasAPIKey
        syncEnabled = AIProfileStore.syncEnabled
    }
}
