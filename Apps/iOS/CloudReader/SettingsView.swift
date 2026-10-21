import SwiftUI
import CloudReaderCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @AppStorage("googleDrive.clientID") private var googleClientID = ""
    @AppStorage("dropbox.clientID") private var dropboxClientID = ""
    @AppStorage("pCloud.clientID") private var pCloudClientID = ""
    @AppStorage("webdav.url") private var webDAVURL = ""
    @AppStorage("sftp.host") private var sftpHost = ""
    @AppStorage("sftp.port") private var sftpPort = "22"
    @AppStorage("sftp.username") private var sftpUsername = ""
    @AppStorage("sftp.directory") private var sftpDirectory = "CloudReader"
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var googleClientSecret = ""
    @State private var sftpPassword = ""
    @State private var sftpHostKey = ""
    @State private var showingFolderPicker = false
    @State private var aiProfile = AIProfileStore.load()
    @State private var aiAPIKey = ""
    @State private var aiHasSavedKey = AIProfileStore.hasAPIKey
    @State private var aiSaveMessage: String?
    @State private var connectingProvider: CloudProviderKind?
    @State private var cloudAlertTitle = "Cloud storage"
    @State private var cloudAlertMessage = ""
    @State private var showingCloudAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("CloudReader")
                                .font(.system(size: 18, weight: .semibold, design: .serif))
                            Text("A quiet place for your books")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(Color(red: 0.53, green: 0.39, blue: 0.27))
                    }
                    .padding(.vertical, 8)
                }

                Section("Your library") {
                    Label("Stored on this device", systemImage: "iphone.gen3")
                    Label("Works offline", systemImage: "wifi.slash")
                    Label("Original files stay untouched", systemImage: "doc.on.doc")
                }

                Section {
                    providerCard(.googleDrive) {
                        TextField("iOS OAuth client ID", text: $googleClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("OAuth client secret (if provided)", text: $googleClientSecret)
                        Text("Create an iOS OAuth client for this app’s bundle ID in Google Cloud Console. This iOS client ID is separate from the Desktop client used on Mac. If Google provided a client secret, enter it here; CloudReader stores it in this device’s Keychain. The callback is derived from the iOS client ID.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        connectButton(.googleDrive, clientID: googleClientID, clientSecret: googleClientSecret)
                    }
                    providerCard(.dropbox) {
                        TextField("OAuth app key", text: $dropboxClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("Enable file content and metadata read/write permissions for the Dropbox app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        connectButton(.dropbox, clientID: dropboxClientID)
                    }
                    providerCard(.pCloud) {
                        TextField("pCloud app ID", text: $pCloudClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Create an app in the pCloud developer console and register cloudreader://pcloud-oauth as its redirect URI.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        connectButton(.pCloud, clientID: pCloudClientID)
                    }
                    providerCard(.webDAV) {
                        TextField("https://server.example/dav", text: $webDAVURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Username", text: $webDAVUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $webDAVPassword)
                        Button("Save WebDAV connection") {
                            Task {
                                await cloudSync.connectWebDAV(url: webDAVURL, username: webDAVUsername, password: webDAVPassword)
                                if cloudSync.isConnected(.webDAV) { await cloudSync.sync(library: library) }
                            }
                        }
                        .disabled(webDAVURL.isEmpty || webDAVUsername.isEmpty)
                    }
                    providerCard(.sftp) {
                        TextField("Server address", text: $sftpHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            TextField("Port", text: $sftpPort).keyboardType(.numberPad)
                            TextField("Username", text: $sftpUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        SecureField("Password", text: $sftpPassword)
                        TextField("Remote CloudReader folder", text: $sftpDirectory)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSH host public key (OpenSSH format)", text: $sftpHostKey, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...3)
                        Text("Pin the server’s public host key to prevent connecting to an impostor server. Ask your server administrator for the ssh-ed25519 or ssh-rsa host public key.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Save SFTP connection") {
                            Task {
                                await cloudSync.connectSFTP(host: sftpHost, port: sftpPort, username: sftpUsername, password: sftpPassword, directory: sftpDirectory, pinnedHostKey: sftpHostKey)
                                if cloudSync.isConnected(.sftp) { await cloudSync.sync(library: library) }
                            }
                        }
                        .disabled(sftpHost.isEmpty || sftpUsername.isEmpty || sftpPassword.isEmpty || sftpHostKey.isEmpty)
                    }
                } header: {
                    Text("Cloud library")
                } footer: {
                    Text("Connect any providers you want, then select multiple destinations below. CloudReader merges books, progress, bookmarks, deletions, and saved AI conversations across them. Conversation context you included, such as a selected passage, syncs with its chat. Connections are configured separately on each device; secrets stay in this device’s Keychain. Use HTTPS for WebDAV.")
                }

                Section("Other locations") {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label("Choose a sync folder in Files", systemImage: "folder.badge.plus")
                    }
                    .foregroundStyle(.primary)
                    Text("Choose an iCloud Drive folder, a mounted SMB share, or a folder supplied by a Files provider app. This works with other storage apps that expose locations in Files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("CloudReader stores a subfolder named CloudReader inside the selected folder. The same folder can be selected on another device to sync the library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("MEGA and PikPak can be used here only when their installed apps expose a folder in Files. Direct MEGA and PikPak connections are not available in this iOS build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Sync") {
                    ForEach(CloudProviderKind.allCases) { provider in
                        Toggle(isOn: destinationSelection(provider)) {
                            Label(provider.title, systemImage: provider.symbol)
                        }
                        .disabled(!cloudSync.isConnected(provider) || cloudSync.isSyncing)
                    }
                    Text("Connect a provider above before selecting it. Select the same destinations on each device; CloudReader merges their contents and keeps each selected destination up to date.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(cloudSync.statusMessage, systemImage: cloudSync.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.icloud")
                    if let lastSync = cloudSync.lastSync {
                        LabeledContent("Last synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        Task { await cloudSync.sync(library: library) }
                    } label: {
                        Label(cloudSync.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(cloudSync.isSyncing || !cloudSync.canSync)
                    if let error = cloudSync.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Text("Books, reading state, bookmarks, deletion records, and saved AI conversations are stored locally and synced to every selected destination when the app is open. Conversation history includes saved book context. Deletions are recorded so other devices can apply them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Reading") {
                    LabeledContent("Native readers", value: "EPUB · PDF · TXT")
                    Text("Additional book formats can be imported and kept in your library, with native readers arriving in later iOS updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("AI provider", selection: $aiProfile.modelSource) {
                        ForEach(AIModelSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    if aiProfile.modelSource == .remoteAPI {
                        TextField("Profile name", text: $aiProfile.name)
                        Picker("API format", selection: $aiProfile.endpointKind) {
                            ForEach(AIEndpointKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        TextField("Model ID, e.g. \(aiProfile.endpointKind.placeholderModel)", text: $aiProfile.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Full endpoint URL (optional)", text: $aiProfile.endpointURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField(aiHasSavedKey ? "Replace saved API key (optional)" : "API key", text: $aiAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if aiHasSavedKey {
                            Label("API key stored in this device’s Keychain", systemImage: "lock.shield")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(AIService.onDeviceAvailabilityDescription, systemImage: "iphone.gen3.radiowaves.left.and.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Save AI settings") {
                        do {
                            try AIProfileStore.save(aiProfile, apiKey: aiAPIKey)
                            aiAPIKey = ""
                            aiHasSavedKey = AIProfileStore.hasAPIKey
                            aiSaveMessage = "AI settings saved."
                        } catch {
                            aiSaveMessage = error.localizedDescription
                        }
                    }
                    if aiHasSavedKey {
                        Button("Remove saved API key", role: .destructive) {
                            AIProfileStore.removeAPIKey()
                            aiHasSavedKey = false
                            aiSaveMessage = "Saved API key removed from this device."
                        }
                    }
                    if let aiSaveMessage {
                        Text(aiSaveMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI assistant")
                } footer: {
                    Text(aiProfile.modelSource == .appleOnDevice
                         ? "Questions are processed on this device when Apple Intelligence is available. Siri’s Ask CloudReader action uses the selected provider."
                         : "Supports OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and compatible custom endpoints. Leave the endpoint blank for the provider default. Questions and optional book text are sent only when you ask; credentials stay in Keychain. Siri’s Ask CloudReader action uses this provider.")
                }

                Section {
                    LabeledContent("Version", value: "0.2 · iOS 26+")
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                googleClientSecret = SecureVault.load(OAuthClientSecret.self, account: "googleDrive.clientSecret")?.value ?? ""
            }
            .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let folder = urls.first else { return }
                    cloudSync.chooseFilesFolder(folder)
                    if cloudSync.isConnected(.filesFolder) {
                        Task { await cloudSync.sync(library: library) }
                    }
                case .failure(let error): cloudSync.report(error)
                }
            }
            .alert(cloudAlertTitle, isPresented: $showingCloudAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(cloudAlertMessage)
            }
        }
    }

    private func destinationSelection(_ provider: CloudProviderKind) -> Binding<Bool> {
        Binding(get: { cloudSync.isSelected(provider) }, set: { cloudSync.setSelected(provider, selected: $0) })
    }

    @ViewBuilder
    private func providerCard<Content: View>(_ provider: CloudProviderKind, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.36, blue: 0.27))
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                Text(provider.title).font(.system(size: 16, weight: .semibold, design: .serif))
                Spacer()
                if cloudSync.isConnected(provider) {
                    Text("Connected").font(.caption.weight(.medium)).foregroundStyle(.green)
                }
            }
            content()
            if cloudSync.isConnected(provider) {
                Button("Disconnect", role: .destructive) { cloudSync.disconnect(provider) }
                    .font(.footnote)
            }
        }
        .padding(.vertical, 5)
    }

    private func connectButton(_ provider: CloudProviderKind, clientID: String, clientSecret: String? = nil) -> some View {
        Button {
            let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedClientID.isEmpty else {
                cloudAlertTitle = "Add your \(provider.title) app ID"
                cloudAlertMessage = "Enter the OAuth client ID or app key from \(provider.title)'s developer console first. CloudReader does not include a shared provider key."
                showingCloudAlert = true
                return
            }
            Task {
                connectingProvider = provider
                defer { connectingProvider = nil }
                let didConnect = await cloudSync.connectOAuth(provider, clientID: normalizedClientID, clientSecret: clientSecret)
                if didConnect { await cloudSync.sync(library: library) }
                cloudAlertTitle = didConnect ? "\(provider.title) connection" : "Couldn’t connect to \(provider.title)"
                cloudAlertMessage = cloudSync.errorMessage ?? (didConnect ? "Connected to \(provider.title)." : "Sign-in did not complete.")
                showingCloudAlert = true
            }
        } label: {
            if connectingProvider == provider {
                Label("Connecting…", systemImage: "hourglass")
            } else {
                Label(cloudSync.isConnected(provider) ? "Reconnect" : "Sign in with \(provider.title)", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
        .disabled(connectingProvider != nil)
    }
}
