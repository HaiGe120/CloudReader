import AppKit
import CloudReaderCore
import ImageIO
import SwiftUI

/// AppKit-owned location and gesture state shared by the view and its focused tests.
@MainActor
final class MacComicReaderState: ObservableObject {
    @Published private(set) var firstPage = 0
    @Published private(set) var zoomScale: CGFloat = 1
    @Published private(set) var panOffset = CGSize.zero
    private(set) var consumedRequestID: UUID?
    private(set) var scrollPosition = 0.0

    func restore(progress: Double, pageCount: Int, columns: Int) {
        firstPage = Self.aligned(Self.page(for: progress, count: pageCount), count: pageCount, columns: columns)
        scrollPosition = Self.progress(page: firstPage, count: pageCount)
    }

    @discardableResult
    func move(by delta: Int, pageCount: Int, columns: Int) -> Bool {
        let next = Self.aligned(firstPage + delta * max(columns, 1), count: pageCount, columns: columns)
        guard next != firstPage else { return false }
        firstPage = next
        zoomScale = 1
        panOffset = .zero
        scrollPosition = Self.progress(page: next, count: pageCount)
        return true
    }

    @discardableResult
    func seek(_ progress: Double, pageCount: Int, columns: Int) -> Bool {
        let next = Self.aligned(Self.page(for: progress, count: pageCount), count: pageCount, columns: columns)
        guard next != firstPage else { return false }
        firstPage = next
        zoomScale = 1
        panOffset = .zero
        scrollPosition = Self.progress(page: next, count: pageCount)
        return true
    }

    @discardableResult
    func consume(_ request: ReaderNavigationRequest?, pageCount: Int, columns: Int) -> Bool {
        guard let request, request.id != consumedRequestID else { return false }
        consumedRequestID = request.id
        switch request.command {
        case .previous: return move(by: -1, pageCount: pageCount, columns: columns)
        case .next: return move(by: 1, pageCount: pageCount, columns: columns)
        case .seek(let value): return seek(value, pageCount: pageCount, columns: columns)
        case .chapter, .previousChapter, .nextChapter: return false
        }
    }

    func setScrollPosition(_ position: Double, pageCount: Int) {
        let page = Self.page(for: position, count: pageCount)
        firstPage = page
        scrollPosition = Self.progress(page: page, count: pageCount)
    }

    func setZoom(_ value: CGFloat, pan: CGSize = .zero) {
        zoomScale = min(max(value.isFinite ? value : 1, 1), 5)
        panOffset = zoomScale == 1 ? .zero : pan
    }

    static func page(for progress: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let value = progress.isFinite ? min(max(progress, 0), 1) : 0
        return Int((value * Double(count - 1)).rounded())
    }

    static func aligned(_ page: Int, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(page, 0) / max(columns, 1) * max(columns, 1), count - 1)
    }

    static func progress(page: Int, count: Int) -> Double {
        count <= 1 ? 0 : Double(min(max(page, 0), count - 1)) / Double(count - 1)
    }
}

@MainActor
private final class MacComicImageCache {
    static let shared = MacComicImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.totalCostLimit = 64 * 1_024 * 1_024 }

    func image(at url: URL, maxPixel: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
            ] as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        let result = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        cache.setObject(result, forKey: key, cost: overflow ? 64 * 1_024 * 1_024 : cost)
        return result
    }
}

struct MacComicBookReader: View {
    let bookID: UUID
    let url: URL
    let sourceFormat: BookFormat
    let progress: Double
    let pageLayoutRaw: String
    let background: Color
    let onProgressChanged: (Double) -> Void
    var isChromeVisible = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onContentTap: () -> Void = {}
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }

    @StateObject private var state = MacComicReaderState()
    @State private var publication: CBZPublication?
    @State private var loadError: String?
    @State private var loadID = UUID()
    @State private var viewport = CGSize.zero

    private var layout: ReaderPageLayout { ReaderPageLayout(rawValue: pageLayoutRaw) ?? .scroll }
    private var columns: Int { layout == .facingPages && viewport.width >= ReaderLayoutMetrics.spreadBreakpoint ? 2 : 1 }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let publication {
                    if layout == .scroll {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 12) {
                                    ForEach(publication.pages.indices, id: \.self) { index in
                                        MacComicCanvas(urls: [publication.url(for: index)], background: background,
                                                       maxPixel: Int(max(geometry.size.width, geometry.size.height) * (NSScreen.main?.backingScaleFactor ?? 2)),
                                                       pagingEnabled: false, zoomScale: 1, panOffset: .zero,
                                                       onPage: { _ in }, onZoom: { _, _ in }, onTap: onContentTap)
                                            .frame(height: max(geometry.size.height, 1))
                                            .id(index)
                                            .background(GeometryReader { frame in
                                                Color.clear.preference(key: MacComicVisiblePageKey.self,
                                                    value: [index: frame.frame(in: .named("comicScroll")).midY])
                                            })
                                    }
                                }.padding(.vertical, 12)
                            }
                            .coordinateSpace(name: "comicScroll")
                            .onPreferenceChange(MacComicVisiblePageKey.self) { positions in
                                guard let nearest = positions.min(by: { abs($0.value - geometry.size.height / 2) < abs($1.value - geometry.size.height / 2) })?.key else { return }
                                state.setScrollPosition(MacComicReaderState.progress(page: nearest, count: publication.pages.count), pageCount: publication.pages.count)
                                onProgressChanged(state.scrollPosition)
                                emit(publication)
                            }
                            .onChange(of: navigationRequest) { _, request in
                                guard state.consume(request, pageCount: publication.pages.count, columns: 1) else { emit(publication); return }
                                withAnimation { proxy.scrollTo(state.firstPage, anchor: .top) }
                                emit(publication)
                            }
                            .onAppear { proxy.scrollTo(state.firstPage, anchor: .top) }
                        }
                    } else {
                        MacComicCanvas(urls: pageURLs(publication), background: background,
                                       maxPixel: Int(max(geometry.size.width, geometry.size.height) * (NSScreen.main?.backingScaleFactor ?? 2)),
                                       pagingEnabled: true,
                                       zoomScale: state.zoomScale, panOffset: state.panOffset,
                                       onPage: { delta in
                                           guard state.move(by: delta, pageCount: publication.pages.count, columns: columns) else { return }
                                           onProgressChanged(state.scrollPosition); emit(publication)
                                       },
                                       onZoom: { zoom, pan in state.setZoom(zoom, pan: pan) },
                                       onTap: onContentTap)
                            .onChange(of: navigationRequest) { _, request in
                                _ = state.consume(request, pageCount: publication.pages.count, columns: columns)
                                onProgressChanged(state.scrollPosition); emit(publication)
                            }
                            .onChange(of: state.firstPage) { _, _ in emit(publication) }
                    }
                } else if loadError == nil { ProgressView("Preparing comic…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .onAppear { viewport = geometry.size }
            .onChange(of: geometry.size) { _, size in
                let wasTwo = columns == 2
                viewport = size
                let nowTwo = layout == .facingPages && size.width >= ReaderLayoutMetrics.spreadBreakpoint
                guard wasTwo != nowTwo, let publication else { return }
                state.restore(progress: state.scrollPosition, pageCount: publication.pages.count, columns: nowTwo ? 2 : 1)
                emit(publication)
            }
            .onChange(of: pageLayoutRaw) { _, _ in
                guard let publication else { return }
                state.restore(progress: state.scrollPosition, pageCount: publication.pages.count, columns: columns)
                onProgressChanged(state.scrollPosition)
                emit(publication)
            }
            .onChange(of: isChromeVisible) { _, _ in
                // Chrome changes only the surrounding controls; reader location and zoom are retained.
            }
        }
        .overlay {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't open \(sourceFormat.displayName)", systemImage: "book.closed")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { self.loadError = nil; loadID = UUID() }
                }.background(background)
            }
        }
        .task(id: MacComicSource(url: url, id: loadID)) {
            publication = nil; loadError = nil
            do {
                let loaded = try await sourceFormat == .cbr
                    ? CBRLoader.shared.open(url: url, bookID: bookID)
                    : CBZLoader.shared.open(url: url, bookID: bookID)
                try Task.checkCancellation()
                publication = loaded
                state.restore(progress: progress, pageCount: loaded.pages.count, columns: columns)
                onProgressChanged(state.scrollPosition); emit(loaded)
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; loadError = error.localizedDescription }
        }
    }

    private func pageURLs(_ publication: CBZPublication) -> [URL] {
        (0..<columns).compactMap { offset in
            let index = state.firstPage + offset
            return index < publication.pages.count ? publication.url(for: index) : nil
        }
    }

    private func emit(_ publication: CBZPublication) {
        let count = publication.pages.count
        let first = min(state.firstPage, max(count - 1, 0))
        let last = min(first + (layout == .scroll ? 0 : columns - 1), max(count - 1, 0))
        let value = MacComicReaderState.progress(page: first, count: count)
        onNavigationStateChanged(ReaderNavigationState(progress: value, pageRange: (first + 1)...(last + 1), pageCount: count,
            canNavigatePrevious: first > 0, canNavigateNext: last < count - 1))
    }

    private struct MacComicSource: Hashable { let url: URL; let id: UUID }
}

private struct MacComicVisiblePageKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct MacComicCanvas: NSViewRepresentable {
    let urls: [URL]
    let background: Color
    let maxPixel: Int
    let pagingEnabled: Bool
    let zoomScale: CGFloat
    let panOffset: CGSize
    let onPage: (Int) -> Void
    let onZoom: (CGFloat, CGSize) -> Void
    let onTap: () -> Void

    func makeNSView(context: Context) -> MacComicCanvasView {
        let view = MacComicCanvasView()
        view.configure(urls: urls, background: NSColor(background), maxPixel: maxPixel, pagingEnabled: pagingEnabled,
                       zoomScale: zoomScale, panOffset: panOffset,
                       onPage: onPage, onZoom: onZoom, onTap: onTap)
        return view
    }
    func updateNSView(_ view: MacComicCanvasView, context: Context) {
        view.configure(urls: urls, background: NSColor(background), maxPixel: maxPixel, pagingEnabled: pagingEnabled,
                       zoomScale: zoomScale, panOffset: panOffset,
                       onPage: onPage, onZoom: onZoom, onTap: onTap)
    }
}

@MainActor
final class MacComicCanvasView: NSView {
    private var urls: [URL] = []
    private var images: [NSImage?] = []
    private var backgroundColor = NSColor.clear
    private var maxPixel = 1
    private var pagingEnabled = false
    private var onPage: (Int) -> Void = { _ in }
    private var onZoom: (CGFloat, CGSize) -> Void = { _, _ in }
    private var onTap: () -> Void = {}
    private var zoom: CGFloat = 1
    private var pan = CGSize.zero
    private var mouseDownPoint: NSPoint?
    private var imageLoadID = UUID()
    private var imageLoadTask: Task<Void, Never>?
    private var wheelAccumulation: CGFloat = 0
    private var wheelGestureActive = false
    private var wheelGestureSent = false
    private var wheelAwaitingMomentum = false
    private var discreteWheelAccumulation: CGFloat = 0
    private var discreteWheelWork: DispatchWorkItem?
    private var pendingClick: DispatchWorkItem?
    private var mouseWasDragged = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func configure(urls: [URL], background: NSColor, maxPixel: Int, pagingEnabled: Bool,
                   zoomScale: CGFloat, panOffset: CGSize,
                   onPage: @escaping (Int) -> Void, onZoom: @escaping (CGFloat, CGSize) -> Void, onTap: @escaping () -> Void) {
        let pagesChanged = self.urls != urls
        let changed = pagesChanged || self.maxPixel != maxPixel
        self.urls = urls; self.backgroundColor = background; self.maxPixel = maxPixel; self.pagingEnabled = pagingEnabled
        self.onPage = onPage; self.onZoom = onZoom; self.onTap = onTap
        self.zoom = zoomScale; self.pan = panOffset
        if changed {
            imageLoadTask?.cancel()
            imageLoadID = UUID()
            let requestID = imageLoadID
            if pagesChanged {
                images = Array(repeating: nil, count: urls.count)
            } else if images.count != urls.count {
                images = Array(repeating: nil, count: urls.count)
            }
            imageLoadTask = Task { [weak self] in
                for (index, url) in urls.enumerated() {
                    guard !Task.isCancelled else { return }
                    let image = await MacComicImageCache.shared.image(at: url, maxPixel: maxPixel)
                    guard let self, self.imageLoadID == requestID, self.urls == urls else { return }
                    self.images[index] = image
                    self.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill(); bounds.fill()
        guard !urls.isEmpty else { return }
        let gap: CGFloat = urls.count > 1 ? 28 : 0
        let pageWidth = max((bounds.width - gap) / CGFloat(urls.count), 1)
        for index in urls.indices {
            guard let image = images[safe: index] ?? nil else { continue }
            let pageRect = CGRect(x: CGFloat(index) * (pageWidth + gap), y: 0, width: pageWidth, height: bounds.height)
            let ratio = min(pageRect.width / max(image.size.width, 1), pageRect.height / max(image.size.height, 1))
            let fitted = CGRect(x: pageRect.midX - image.size.width * ratio / 2,
                                y: pageRect.midY - image.size.height * ratio / 2,
                                width: image.size.width * ratio, height: image.size.height * ratio)
            let scaled = CGRect(x: fitted.midX - fitted.width * zoom / 2 + pan.width,
                                y: fitted.midY - fitted.height * zoom / 2 + pan.height,
                                width: fitted.width * zoom, height: fitted.height * zoom)
            image.draw(in: scaled)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        cancelPendingClick()
        if zoom > 1 {
            panBy(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            return
        }
        guard pagingEnabled else { super.scrollWheel(with: event); return }
        handleWheel(deltaX: event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX,
                    precise: event.hasPreciseScrollingDeltas, phase: event.phase, momentumPhase: event.momentumPhase)
    }

    /// Kept on the AppKit view so the physical gesture recognizer can be tested directly.
    func handleWheel(deltaX: CGFloat, precise: Bool, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        guard pagingEnabled, zoom == 1, deltaX.isFinite else { return }
        if phase.isEmpty && momentumPhase.isEmpty {
            guard deltaX != 0 else { return }
            discreteWheelAccumulation += deltaX
            discreteWheelWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finishDiscreteWheelGesture() }
            discreteWheelWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            return
        }

        if phase.contains(.began), momentumPhase.isEmpty {
            wheelGestureActive = true
            wheelGestureSent = false
            wheelAccumulation = 0
            wheelAwaitingMomentum = false
        } else if momentumPhase.contains(.began), !wheelGestureActive {
            wheelGestureActive = true
            wheelAccumulation = 0
            // A gesture already paged before momentum; keep suppressing its tail.
            wheelGestureSent = wheelAwaitingMomentum
        } else if !wheelGestureActive {
            wheelGestureActive = true
            wheelGestureSent = false
            wheelAccumulation = 0
        }

        wheelAccumulation += deltaX
        if !wheelGestureSent, abs(wheelAccumulation) >= (precise ? 24 : 1) {
            wheelGestureSent = true
            onPage(wheelAccumulation < 0 ? 1 : -1)
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            wheelGestureActive = false
            wheelAwaitingMomentum = wheelGestureSent
            if momentumPhase.isEmpty && !wheelAwaitingMomentum { resetWheelGesture() }
        }
        if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { resetWheelGesture() }
    }

    func finishDiscreteWheelGesture() {
        discreteWheelWork?.cancel()
        defer { discreteWheelAccumulation = 0; discreteWheelWork = nil }
        guard discreteWheelAccumulation != 0 else { return }
        onPage(discreteWheelAccumulation < 0 ? 1 : -1)
    }

    func panBy(deltaX: CGFloat, deltaY: CGFloat) {
        guard zoom > 1 else { return }
        pan.width += deltaX
        pan.height += deltaY
        onZoom(zoom, pan)
        needsDisplay = true
    }

    private func resetWheelGesture() {
        wheelGestureActive = false
        wheelGestureSent = false
        wheelAwaitingMomentum = false
        wheelAccumulation = 0
    }

    override func swipe(with event: NSEvent) {
        cancelPendingClick()
        guard pagingEnabled, zoom == 1 else { return }
        if abs(event.deltaX) > 0.12 { onPage(event.deltaX < 0 ? 1 : -1) }
    }

    override func keyDown(with event: NSEvent) {
        guard pagingEnabled else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: onPage(-1)
        case 124, 125, 49: onPage(1)
        case 53: zoom = 1; pan = .zero; onZoom(1, .zero); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelPendingClick()
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseWasDragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        if hypot(current.x - start.x, current.y - start.y) >= 5 {
            mouseWasDragged = true
            cancelPendingClick()
        }
        if zoom > 1 {
            pan.width += current.x - start.x; pan.height += current.y - start.y
            mouseDownPoint = current; onZoom(zoom, pan); needsDisplay = true
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; mouseWasDragged = false }
        guard let start = mouseDownPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        guard !mouseWasDragged, hypot(end.x - start.x, end.y - start.y) < 5 else { return }
        if event.clickCount >= 2 {
            cancelPendingClick()
            zoom = zoom > 1 ? 1 : 2
            if zoom == 1 { pan = .zero }
            onZoom(zoom, pan); needsDisplay = true
        } else {
            cancelPendingClick()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingClick = nil
                self.onTap()
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    override func magnify(with event: NSEvent) {
        cancelPendingClick()
        zoom = min(max(zoom + event.magnification, 1), 5)
        if zoom == 1 { pan = .zero }
        onZoom(zoom, pan); needsDisplay = true
    }

    private func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
