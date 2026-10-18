import AppIntents
import SwiftUI

@main
struct CloudReaderApp: App {
    @StateObject private var library = BookLibrary.shared
    @StateObject private var cloudSync = CloudSyncCoordinator()

    init() {
        CloudReaderShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(library)
                .environmentObject(cloudSync)
                .tint(Color(red: 0.40, green: 0.34, blue: 0.28))
        }
    }
}

private enum AppTab: Hashable {
    case library
    case settings
}

private struct RootTabView: View {
    @EnvironmentObject private var library: BookLibrary
    @EnvironmentObject private var cloudSync: CloudSyncCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .library
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryView()
            }

            Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) {
                SettingsView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scheduleSync() }
        }
        .onChange(of: library.books) {
            scheduleSync()
        }
        .onChange(of: library.aiConversations) {
            scheduleSync()
        }
        .onAppear {
            library.installDemoBookIfNeeded()
            scheduleSync()
        }
    }

    private func scheduleSync() {
        guard cloudSync.canSync else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await cloudSync.sync(library: library)
        }
    }
}
