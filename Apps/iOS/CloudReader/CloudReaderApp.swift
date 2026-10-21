import AppIntents
import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

@main
struct CloudReaderApp: App {
    @StateObject private var library: BookLibrary
    @StateObject private var cloudSync: CloudSyncCoordinator
    private let isTestHost: Bool
    private let isUITestMode: Bool
    private let uiTestDefaults: UserDefaults?

    init() {
        let environment = ProcessInfo.processInfo.environment
        isUITestMode = environment["CLOUDREADER_UI_TEST_MODE"] == "1"
        isTestHost = environment["CLOUDREADER_TEST_HOST"] == "1" && !isUITestMode
        if isUITestMode {
            let suffix = UUID().uuidString
            let suiteName = "CloudReader-ReaderUITest-\(suffix)"
            let suite = UserDefaults(suiteName: suiteName)!
            uiTestDefaults = suite
            suite.set("singlePage", forKey: "reader.pageLayout")
            let storage = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudReader-ReaderUITest-\(suffix)", isDirectory: true)
            let isolatedLibrary = BookLibrary(storageDirectory: storage, defaults: suite)
            let fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reader UI Test Book-\(suffix).txt")
            let epubFixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reader Swipe Test Book-\(suffix).epub")
            let cbzFixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reader Comic UI Test Book-\(suffix).cbz")
            let fb2Fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reader FB2 UI Test Book-\(suffix).fb2")
            let pdfFixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reader PDF UI Test Book-\(suffix).pdf")
            let fixtureText = """
            Reader UI Test Book

            This isolated fixture checks that the reading view fills the screen when its controls hide. Tap this text to hide controls, then tap again to restore them.

            继续阅读。中文排版应保持清晰，换行和段落位置应稳定。
            """
            do {
                try Data(fixtureText.utf8).write(to: fixture)
                try ReaderUITestFixture.writeEPUB(at: epubFixture)
                try ReaderUITestFixture.writeCBZ(at: cbzFixture)
                try ReaderUITestFixture.writeFB2(at: fb2Fixture)
                try ReaderUITestFixture.writePDF(at: pdfFixture)
                isolatedLibrary.importBooks(from: [fixture, epubFixture, cbzFixture, fb2Fixture, pdfFixture])
                isolatedLibrary.alertMessage = nil
            } catch {
                assertionFailure("Could not create the isolated reader UI-test fixture: \(error)")
            }
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: epubFixture)
            try? FileManager.default.removeItem(at: cbzFixture)
            try? FileManager.default.removeItem(at: fb2Fixture)
            try? FileManager.default.removeItem(at: pdfFixture)
            _library = StateObject(wrappedValue: isolatedLibrary)
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator(defaults: suite))
        } else if isTestHost {
            uiTestDefaults = nil
            let suite = UserDefaults(suiteName: "CloudReader-TestHost-\(UUID().uuidString)")!
            let storage = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudReader-TestHost-\(UUID().uuidString)", isDirectory: true)
            _library = StateObject(wrappedValue: BookLibrary(storageDirectory: storage, defaults: suite))
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator(defaults: suite))
        } else {
            uiTestDefaults = nil
            _library = StateObject(wrappedValue: BookLibrary.shared)
            _cloudSync = StateObject(wrappedValue: CloudSyncCoordinator())
            CloudReaderShortcuts.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            if isTestHost {
                Color.clear
            } else {
                RootTabView(isUITestMode: isUITestMode)
                    .environmentObject(library)
                    .environmentObject(cloudSync)
                    .defaultAppStorage(uiTestDefaults ?? .standard)
                    .tint(Color(red: 0.40, green: 0.34, blue: 0.28))
            }
        }
    }
}

private enum ReaderUITestFixture {
    static func writePDF(at url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for page in 1...3 {
                context.beginPage()
                let text = "Reader PDF UI Test Book — Page \(page)\n\nHide and restore the reader chrome while preserving the current page and its viewport.\n\n中文段落用于验证 PDF 内容页。"
                text.draw(in: CGRect(x: 48, y: 72, width: 516, height: 300), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 22),
                    .foregroundColor: UIColor.black
                ])
            }
        }
        try data.write(to: url)
    }

    static func writeCBZ(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/WQ0AAAAASUVORK5CYII=")!
        let entries: [(String, Data)] = (1...5).map { (String(format: "page%02d.png", $0), image) }
            + [("ComicInfo.xml", Data("<ComicInfo/>".utf8))]
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                let start = Int(position)
                let end = min(start + count, data.count)
                guard start <= end else { return Data() }
                return data.subdata(in: start..<end)
            }
        }
    }

    static func writeFB2(at url: URL) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Reader FB2 UI Test Book</book-title></title-info></description><body><section><title><p>FB2 chapter</p></title><p>FB2 rendering should use the same typography and app theme as EPUB and TXT.</p><p>中文段落应保持一致。</p></section></body></FictionBook>
        """
        try Data(xml.utf8).write(to: url)
    }

    static func writeEPUB(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let chapters = (1...3).map { index in
            let body = (0..<42).map { paragraph in
                "<p>Chapter \(index), passage \(paragraph). The reader keeps this text in a stable place while the page turns. 中文段落用于验证字号、间距和分页。</p>"
            }.joined()
            return ("OEBPS/chapter\(index).xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Chapter \(index)</title></head><body><h1>Chapter \(index)</h1>\(body)</body></html>")
        }
        let navigation = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">First chapter</a></li><li><a href="chapter2.xhtml">Second chapter</a></li><li><a href="chapter3.xhtml">Third chapter</a></li></ol></nav></body></html>
        """
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Reader Swipe Test Book</dc:title></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/><item id="c3" href="chapter3.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/></spine></package>
        """
        let entries = [("mimetype", "application/epub+zip"),
                       ("META-INF/container.xml", "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
                       ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", navigation)] + chapters
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate
            ) { position, count in
                let start = Int(position)
                let end = min(start + count, data.count)
                guard start <= end else { return Data() }
                return data.subdata(in: start..<end)
            }
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
    @StateObject private var imports = BookImportCoordinator()
    let isUITestMode: Bool

    init(isUITestMode: Bool = false) {
        self.isUITestMode = isUITestMode
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryView()
            }

            Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) {
                SettingsView()
            }
        }
        .environmentObject(imports)
        .onOpenURL { url in
            guard url.isFileURL else { return }
            selection = .library
            imports.importFiles([url], library: library)
        }
        .onChange(of: imports.bookToOpen) {
            selection = .library
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if !isUITestMode {
                    imports.receiveSharedBooks(library: library)
                    scheduleSync()
                }
            } else {
                library.flushPendingChanges()
            }
        }
        .onChange(of: library.books) {
            scheduleSync()
        }
        .onChange(of: library.aiConversations) {
            scheduleSync()
        }
        .onAppear {
            guard !isUITestMode else { return }
            library.installDemoBookIfNeeded()
            imports.receiveSharedBooks(library: library)
            scheduleSync()
        }
    }

    private func scheduleSync() {
        guard !isUITestMode, cloudSync.canSync else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            // A library update during synchronization may schedule a later pass,
            // but must not cancel the download that produced that update.
            syncTask = nil
            await cloudSync.sync(library: library)
        }
    }
}

private extension BookImportCoordinator {
    func receiveSharedBooks(library: BookLibrary) {
        guard let urls = try? SharedBookInbox.live.pendingFiles(), !urls.isEmpty else { return }
        importFiles(urls, library: library) { url in
            try SharedBookInbox.live.removeFile(at: url)
        }
    }
}
