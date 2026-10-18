import SwiftUI
import UniformTypeIdentifiers

struct MacSettingsView: View {
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
    @State private var isChoosingFolder = false
    @State private var aiProfile = AIProfileStore.load()
    @State private var aiAPIKey = ""
    @State private var aiHasSavedKey = AIProfileStore.hasAPIKey
    @State private var aiSaveMessage: String?

    var body: some View {
        Form {
            Section {
                Label("Books are stored in CloudReader’s local library. Original imported files are left in place.", systemImage: "internaldrive")
                Label("Select one or more connected destinations on both devices to share books, favorites, reading progress, and saved AI conversations.", systemImage: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Your library")
            }

            Section("Google Drive") {
                TextField("Desktop OAuth client ID", text: $googleClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Desktop OAuth client secret (optional)", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                Text("Use a Desktop app OAuth client from Google Cloud Console. Google lists the secret as optional for native apps, but some token exchanges require it. Native apps cannot keep a distributed secret confidential; CloudReader stores the value in this Mac’s Keychain. The iOS client ID is separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerStatus(.googleDrive)
                HStack {
                    Button(cloudSync.isConnected(.googleDrive) ? "Reconnect" : "Connect") {
                        Task {
                            let didConnect = await cloudSync.connectOAuth(.googleDrive, clientID: googleClientID, clientSecret: googleClientSecret)
                            if didConnect { await cloudSync.sync(library: library) }
                        }
                    }
                    .disabled(googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    disconnectButton(.googleDrive)
                }
            }

            Section("Dropbox") {
                TextField("Dropbox app key", text: $dropboxClientID)
                    .textFieldStyle(.roundedBorder)
                Text("Enable file content and metadata read/write permissions in the Dropbox App Console. Register \(dropboxCallbackURI) as the redirect URI. CloudReader uses PKCE with offline refresh tokens, so a client secret is not required in this Mac app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerStatus(.dropbox)
                HStack {
                    Button(cloudSync.isConnected(.dropbox) ? "Reconnect" : "Connect") {
                        Task {
                            let didConnect = await cloudSync.connectOAuth(.dropbox, clientID: dropboxClientID)
                            if didConnect { await cloudSync.sync(library: library) }
                        }
                    }
                    .disabled(dropboxClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    disconnectButton(.dropbox)
                }
            }

            Section("pCloud") {
                TextField("pCloud app ID", text: $pCloudClientID)
                    .textFieldStyle(.roundedBorder)
                Text("Register cloudreader://pcloud-oauth as the pCloud app redirect URI, then enter its app ID here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerStatus(.pCloud)
                HStack {
                    Button(cloudSync.isConnected(.pCloud) ? "Reconnect" : "Connect") {
                        Task {
                            let didConnect = await cloudSync.connectOAuth(.pCloud, clientID: pCloudClientID)
                            if didConnect { await cloudSync.sync(library: library) }
                        }
                    }
                    .disabled(pCloudClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    disconnectButton(.pCloud)
                }
            }

            Section("WebDAV") {
                TextField("HTTPS server URL", text: $webDAVURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $webDAVUsername)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $webDAVPassword)
                    .textFieldStyle(.roundedBorder)
                providerStatus(.webDAV)
                HStack {
                    Button("Save and connect") {
                        Task {
                            await cloudSync.connectWebDAV(url: webDAVURL, username: webDAVUsername, password: webDAVPassword)
                            if cloudSync.isConnected(.webDAV) { await cloudSync.sync(library: library) }
                        }
                    }
                    .disabled(webDAVURL.isEmpty || webDAVUsername.isEmpty || webDAVPassword.isEmpty)
                    disconnectButton(.webDAV)
                }
            }

            Section("SFTP") {
                TextField("Server address", text: $sftpHost)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Port", text: $sftpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    TextField("Username", text: $sftpUsername)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("Password", text: $sftpPassword)
                    .textFieldStyle(.roundedBorder)
                TextField("Remote folder", text: $sftpDirectory)
                    .textFieldStyle(.roundedBorder)
                TextField("Pinned SSH host public key (OpenSSH format)", text: $sftpHostKey, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
                Text("Pin the server’s public key to verify its identity before connecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerStatus(.sftp)
                HStack {
                    Button("Save and connect") {
                        Task {
                            await cloudSync.connectSFTP(host: sftpHost, port: sftpPort, username: sftpUsername, password: sftpPassword, directory: sftpDirectory, pinnedHostKey: sftpHostKey)
                            if cloudSync.isConnected(.sftp) { await cloudSync.sync(library: library) }
                        }
                    }
                    .disabled(sftpHost.isEmpty || sftpUsername.isEmpty || sftpPassword.isEmpty || sftpHostKey.isEmpty)
                    disconnectButton(.sftp)
                }
            }

            Section("Files folder") {
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("Choose a folder…", systemImage: "folder.badge.plus")
                }
                providerStatus(.filesFolder)
                Text("A folder in iCloud Drive or a provider mounted in Finder can be selected on each device. CloudReader stores its own subfolder inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("MEGA and PikPak are available through this route only when their installed apps expose folders in Files or Finder. Direct adapters are not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                ForEach(CloudProviderKind.allCases) { provider in
                    Toggle(isOn: destinationSelection(provider)) {
                        Label(provider.title, systemImage: provider.symbol)
                    }
                    .disabled(!cloudSync.isConnected(provider) || cloudSync.isSyncing)
                }
                Text("Connect a provider above before selecting it. CloudReader merges selected destinations and updates each one when the app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: cloudSync.isSyncing ? "Syncing…" : cloudSync.statusMessage)
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
                    Text(error).foregroundStyle(.red)
                }
                Text("Books, reading positions, bookmarks, deletions, and saved AI conversations sync to every selected destination when this app is open. Credentials stay in this Mac’s Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI assistant") {
                Picker("AI provider", selection: $aiProfile.modelSource) {
                    ForEach(AIModelSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }

                if aiProfile.modelSource == .remoteAPI {
                    TextField("Profile name", text: $aiProfile.name)
                        .textFieldStyle(.roundedBorder)
                    Picker("API format", selection: $aiProfile.endpointKind) {
                        ForEach(AIEndpointKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    TextField("Model ID (e.g. \(aiProfile.endpointKind.placeholderModel))", text: $aiProfile.model)
                        .textFieldStyle(.roundedBorder)
                    TextField("Full endpoint URL (optional)", text: $aiProfile.endpointURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField(aiHasSavedKey ? "Replace saved API key (optional)" : "API key", text: $aiAPIKey)
                        .textFieldStyle(.roundedBorder)
                    if aiHasSavedKey {
                        Label("API key is stored in this Mac’s Keychain", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(AIService.onDeviceAvailabilityDescription, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
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
                            aiSaveMessage = "Saved API key removed from this Mac."
                        }
                    }
                }
                if let aiSaveMessage {
                    Text(aiSaveMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Ask CloudReader is an App Intent. On Mac, add it to a custom shortcut in Shortcuts; on iOS, Siri can use the built-in phrase. Both use the provider selected here. Conversations are not library-synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Readers") {
                LabeledContent("EPUB", value: "Quick Look")
                LabeledContent("PDF", value: "PDFKit")
                LabeledContent("TXT", value: "Adjustable text")
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(minWidth: 620, minHeight: 760)
        .onAppear {
            googleClientSecret = SecureVault.load(OAuthClientSecret.self, account: "googleDrive.clientSecret")?.value ?? ""
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                cloudSync.chooseFilesFolder(folder)
                if cloudSync.isConnected(.filesFolder) { Task { await cloudSync.sync(library: library) } }
            case .failure(let error): cloudSync.report(error)
            }
        }
    }

    private func destinationSelection(_ provider: CloudProviderKind) -> Binding<Bool> {
        Binding(get: { cloudSync.isSelected(provider) }, set: { cloudSync.setSelected(provider, selected: $0) })
    }

    private var dropboxCallbackURI: String {
        let key = dropboxClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? "db-<app-key>://2/token" : "db-\(key)://2/token"
    }

    @ViewBuilder
    private func providerStatus(_ provider: CloudProviderKind) -> some View {
        if cloudSync.isConnected(provider) {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func disconnectButton(_ provider: CloudProviderKind) -> some View {
        if cloudSync.isConnected(provider) {
            Button("Disconnect", role: .destructive) { cloudSync.disconnect(provider) }
        }
    }
}
