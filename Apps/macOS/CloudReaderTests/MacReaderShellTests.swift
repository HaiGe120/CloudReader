import AppKit
import CloudReaderCore
import SwiftUI
import XCTest
@testable import CloudReader

/// Observes the real shell's presentation preference after adapters finish loading.
/// In-process SwiftUI AX wrappers do not expose the external AX attribute API.
@MainActor
final class MacReaderShellTests: XCTestCase {
    func testEveryImportedFormatPublishesMeasuredPagesThroughTheShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacReaderShell-\(UUID())")
        let suiteName = "CloudReader-MacReaderShell-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("singlePage", forKey: "reader.pageLayout")
        let library = BookLibrary(storageDirectory: directory, defaults: defaults)
        try MacReaderUITestFixtures.populate(library: library, environment: ["CLOUDREADER_UI_TEST_FIXTURE_BUNDLE": try XCTUnwrap(Bundle(for: Self.self).resourceURL).path])
        for format in [BookFormat.txt, .pdf, .epub, .mobi, .azw3, .fb2, .cbz, .cbr] {
            let book = try XCTUnwrap(library.books.first { $0.format == format })
            let (window, probe) = makeWindow(book: book, library: library, defaults: defaults)
            defer { window.contentView = nil; window.close() }
            let ready = await waitUntil { (probe.latest?.navigation.pageCount ?? 0) > 0 }
            XCTAssertTrue(ready, "\(format) did not publish measured page state through the actual reader shell")
            XCTAssertNotNil(probe.latest?.navigation.pageRange, "\(format) needs an actual page range")
            XCTAssertEqual(probe.latest?.chromeVisible, true)
            XCTAssertEqual(probe.latest?.appearanceAvailable, true)
        }
    }

    func testNativeComicContentClickHidesAndRestoresShellChrome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacReaderShell-click-\(UUID())")
        let suiteName = "CloudReader-MacReaderShell-click-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("singlePage", forKey: "reader.pageLayout")
        let library = BookLibrary(storageDirectory: directory, defaults: defaults)
        try MacReaderUITestFixtures.populate(library: library, environment: [:])
        let book = try XCTUnwrap(library.books.first { $0.format == .cbz })
        let (window, probe) = makeWindow(book: book, library: library, defaults: defaults)
        defer { window.contentView = nil; window.close() }
        let loaded = await waitUntil { (probe.latest?.navigation.pageCount ?? 0) == 5 }
        XCTAssertTrue(loaded)
        let canvas = try XCTUnwrap(findCanvas(in: try XCTUnwrap(window.contentView)))
        click(canvas, in: window)
        let hidden = await waitUntil { probe.latest?.chromeVisible == false }
        XCTAssertTrue(hidden)
        click(canvas, in: window)
        let restored = await waitUntil { probe.latest?.chromeVisible == true }
        XCTAssertTrue(restored)
        XCTAssertEqual(probe.latest?.navigation.pageRange, 1...1)
    }

    private func makeWindow(book: Book, library: BookLibrary, defaults: UserDefaults) -> (NSWindow, Probe) {
        let probe = Probe()
        let host = NSHostingView(rootView: NavigationStack {
            MacBookReaderView(book: book).environmentObject(library).defaultAppStorage(defaults)
                .onPreferenceChange(MacReaderPresentationKey.self) { probe.latest = $0 }
        })
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, probe)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func findCanvas(in view: NSView) -> MacComicCanvasView? {
        if let canvas = view as? MacComicCanvasView { return canvas }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private final class Probe { var latest: MacReaderPresentation? }
}
