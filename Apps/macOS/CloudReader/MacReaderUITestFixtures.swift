import AppKit
import CloudReaderCore
import PDFKit
import SwiftUI
import ZIPFoundation

/// Isolated fixture setup, entered only with CLOUDREADER_UI_TEST_MODE=1.
@MainActor
enum MacReaderUITestFixtures {
    static func populate(library: BookLibrary, environment: [String: String]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacReaderFixtures-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = (0..<90).map { "Passage \($0). The lighthouse stays in view while the reader reflows. 中文段落用于验证相同字体和分页。" }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: root.appendingPathComponent("Mac TXT Fixture.txt"))
        try writeEPUB(to: root.appendingPathComponent("Mac EPUB Fixture.epub"))
        try Data("<?xml version=\"1.0\"?><FictionBook><description><title-info><book-title>Mac FB2 Fixture</book-title></title-info></description><body><section><title><p>FB2 chapter</p></title><p>English and 中文 share the app typography.</p><p>Before <emphasis>emphasis</emphasis> after.</p></section></body></FictionBook>".utf8).write(to: root.appendingPathComponent("Mac FB2 Fixture.fb2"))
        let comic = try Archive(url: root.appendingPathComponent("Mac CBZ Fixture.cbz"), accessMode: .create)
        for page in 1...5 {
            let image = NSImage(size: NSSize(width: 240, height: 320), flipped: false) { rect in
                NSColor(calibratedHue: CGFloat(page) / 6, saturation: 0.3, brightness: 0.95, alpha: 1).setFill()
                rect.fill()
                ("Page \(page)" as NSString).draw(at: NSPoint(x: 40, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                return true
            }
            var rect = NSRect(x: 0, y: 0, width: 240, height: 320)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try add(data, path: "page\(page).png", to: comic)
        }
        let pdf = PDFDocument()
        for index in 0..<3 {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            view.string = "Mac PDF Fixture — Page \(index + 1)\n\nPreserve selection, destination and zoom while controls hide. 中文内容。"
            view.font = NSFont.systemFont(ofSize: 22)
            guard let page = PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0) else { throw CocoaError(.fileWriteUnknown) }
            pdf.insert(page, at: index)
        }
        guard pdf.write(to: root.appendingPathComponent("Mac PDF Fixture.pdf")) else { throw CocoaError(.fileWriteUnknown) }
        if let fixtureRoot = environment["CLOUDREADER_UI_TEST_FIXTURE_ROOT"] ?? environment["CLOUDREADER_UI_TEST_FIXTURE_BUNDLE"] {
            let isBundle = environment["CLOUDREADER_UI_TEST_FIXTURE_BUNDLE"] != nil
            let shared = isBundle ? URL(fileURLWithPath: fixtureRoot) : URL(fileURLWithPath: fixtureRoot).appendingPathComponent("Apps/iOS/CloudReaderTests")
            for (source, name) in [("KindleFixtures/reflowable-combo.mobi", "Mac MOBI Fixture.mobi"),
                                   ("KindleFixtures/rich-kf8-image-links.azw3", "Mac AZW3 Fixture.azw3"),
                                   ("CBRFixtures/rar5-solid-pages.rar", "Mac CBR Fixture.cbr")] {
                let relativePath = isBundle ? URL(fileURLWithPath: source).lastPathComponent : source
                // Read the small fixture bytes directly. APFS clone-on-copy from
                // coordinated Documents files can stall an app launched by XCTest.
                let bytes = try Data(contentsOf: shared.appendingPathComponent(relativePath))
                try bytes.write(to: root.appendingPathComponent(name), options: .atomic)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        library.importBooks(from: files)
        library.alertMessage = nil
    }

    private static func writeEPUB(to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let package = "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Mac EPUB Fixture</dc:title></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"c1\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c2\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/><itemref idref=\"c2\"/></spine></package>"
        let container = "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        let nav = "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"one.xhtml\">First chapter</a></li><li><a href=\"two.xhtml\">Second chapter</a></li></ol></nav></body></html>"
        for (path, value) in [("mimetype", "application/epub+zip"), ("META-INF/container.xml", container), ("OEBPS/content.opf", package), ("OEBPS/nav.xhtml", nav)] {
            try add(Data(value.utf8), path: path, to: archive)
        }
        for (index, name) in ["one", "two"].enumerated() {
            let body = (0..<42).map { "<p>Chapter \(index + 1), passage \($0). The reader keeps this text in a stable place while a page turns. 中文段落验证字体、间距和分页。</p>" }.joined()
            let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Chapter \(index + 1)</title><style>body{font:900 32px Courier;width:1800px;background:red}p{text-indent:90px}</style></head><body><h1>Chapter \(index + 1)</h1>\(body)</body></html>"
            try add(Data(html.utf8), path: "OEBPS/\(name).xhtml", to: archive)
        }
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, count in
            data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
        }
    }
}

struct MacReaderUITestWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowSizeView() }
    func updateNSView(_ nsView: NSView, context: Context) { }
    private final class WindowSizeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let environment = ProcessInfo.processInfo.environment
            let width = Double(environment["CLOUDREADER_UI_TEST_WIDTH"] ?? "1100") ?? 1100
            let height = Double(environment["CLOUDREADER_UI_TEST_HEIGHT"] ?? "780") ?? 780
            DispatchQueue.main.async { window.setContentSize(NSSize(width: min(max(width, 520), 1600), height: min(max(height, 480), 1200))) }
        }
    }
}
