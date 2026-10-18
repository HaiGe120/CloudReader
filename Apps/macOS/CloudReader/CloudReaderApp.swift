import SwiftUI

@main
struct CloudReaderApp: App {
    @StateObject private var library = BookLibrary.shared
    @StateObject private var cloudSync = CloudSyncCoordinator()

    var body: some Scene {
        WindowGroup {
            MacLibraryView()
                .environmentObject(library)
                .environmentObject(cloudSync)
                .tint(Color(red: 0.40, green: 0.34, blue: 0.28))
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { library.installDemoBookIfNeeded() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Books…", systemImage: "square.and.arrow.down") {
                    NotificationCenter.default.post(name: .cloudReaderImportBooks, object: nil)
                }
            }
        }
        Settings {
            MacSettingsView()
                .environmentObject(library)
                .environmentObject(cloudSync)
        }
    }
}

extension Notification.Name {
    static let cloudReaderImportBooks = Notification.Name("io.github.haige120.cloudreader.importBooks")
}
