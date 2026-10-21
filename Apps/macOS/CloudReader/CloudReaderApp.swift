import SwiftUI

@main
struct CloudReaderApp: App {
    @StateObject private var library: BookLibrary
    @StateObject private var cloudSync: CloudSyncCoordinator
    private let isTestHost: Bool
    private let isUITestMode: Bool
    private let uiTestDefaults: UserDefaults?
    private let uiTestBookID: UUID?

    init() {
        let environment = ProcessInfo.processInfo.environment
        isUITestMode = environment["CLOUDREADER_UI_TEST_MODE"] == "1"
        isTestHost = environment["CLOUDREADER_TEST_HOST"] == "1" && !isUITestMode
        if isUITestMode {
            let session = environment["CLOUDREADER_UI_TEST_SESSION"] ?? UUID().uuidString
            let suite = UserDefaults(suiteName: "CloudReader-MacReaderUITest-\(session)")!
            suite.set(environment["CLOUDREADER_UI_TEST_LAYOUT"] ?? "singlePage", forKey: "reader.pageLayout")
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("CloudReader-MacReaderUITest-\(session)")
            let isolatedLibrary = BookLibrary(storageDirectory: storage, defaults: suite)
            if isolatedLibrary.books.isEmpty {
                do { try MacReaderUITestFixtures.populate(library: isolatedLibrary, environment: environment) }
                catch { assertionFailure("Reader fixture setup failed: \(error)") }
            }
            uiTestDefaults = suite
            uiTestBookID = isolatedLibrary.books.first { $0.format.rawValue == (environment["CLOUDREADER_UI_TEST_FORMAT"] ?? "epub") }?.id
            _library = StateObject(wrappedValue: isolatedLibrary)
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator(defaults: suite))
        } else if isTestHost {
            uiTestDefaults = nil
            uiTestBookID = nil
            let suite = UserDefaults(suiteName: "CloudReader-TestHost-\(UUID().uuidString)")!
            let storage = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudReader-TestHost-\(UUID().uuidString)", isDirectory: true)
            _library = StateObject(wrappedValue: BookLibrary(storageDirectory: storage, defaults: suite))
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator(defaults: suite))
        } else {
            uiTestDefaults = nil
            uiTestBookID = nil
            _library = StateObject(wrappedValue: BookLibrary.shared)
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator())
        }
    }

    var body: some Scene {
        WindowGroup {
            if isTestHost {
                EmptyView()
            } else {
                MacLibraryView(isUITestMode: isUITestMode, initialBookID: uiTestBookID)
                    .environmentObject(library)
                    .environmentObject(cloudSync)
                    .defaultAppStorage(uiTestDefaults ?? .standard)
                    .tint(Color(red: 0.40, green: 0.34, blue: 0.28))
                    .frame(minWidth: 520, minHeight: 480)
                    .background { if isUITestMode { MacReaderUITestWindowConfiguration() } }
                    .onAppear { if !isUITestMode { library.installDemoBookIfNeeded() } }
            }
        }
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Books…", systemImage: "square.and.arrow.down") {
                    NotificationCenter.default.post(name: .cloudReaderImportBooks, object: nil)
                }
            }
        }
        Settings {
            if isTestHost {
                EmptyView()
            } else {
                MacSettingsView()
                    .environmentObject(library)
                    .environmentObject(cloudSync)
                    .defaultAppStorage(uiTestDefaults ?? .standard)
            }
        }
    }
}

extension Notification.Name {
    static let cloudReaderImportBooks = Notification.Name("io.github.haige120.cloudreader.importBooks")
}
