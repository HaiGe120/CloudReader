import Foundation
import SwiftUI
import UIKit
import ImageIO
import CloudReaderCore

private actor CBZImageCache {
    static let shared = CBZImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.totalCostLimit = 64 * 1_024 * 1_024 }

    func image(url: URL, maxPixel: Int) -> UIImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: true
              ] as CFDictionary) else { return nil }
        let result = UIImage(cgImage: image, scale: 1, orientation: .up)
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        cache.setObject(result, forKey: key, cost: overflow ? 64 * 1_024 * 1_024 : cost)
        return result
    }
}

struct CBZBookReader: View {
    @Environment(\.displayScale) private var displayScale
    let bookID: UUID
    let url: URL
    var sourceFormat: BookFormat = .cbz
    let progress: Double
    let pageLayout: ReaderPageLayout
    let palette: ReaderPalette
    var isChromeVisible = true
    var navigationRequest: ReaderNavigationRequest? = nil
    var onNavigationStateChanged: (ReaderNavigationState) -> Void = { _ in }
    var onContentTap: () -> Void = {}

    @State private var publication: CBZPublication?
    @State private var loadError: String?
    @State private var pageIndex = 0
    @State private var viewport = CGSize.zero
    @State private var consumedRequest: UUID?
    @State private var loadID = UUID()

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let publication {
                    if pageLayout == .scroll {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 12) {
                                    ForEach(publication.pages.indices, id: \.self) { index in
                                        pageView(publication, indices: [index], size: geometry.size)
                                            .id(index).background(GeometryReader { frame in Color.clear.preference(key: CBZVisiblePageKey.self, value: [index: frame.frame(in: .named("comicScroll")).midY]) })
                                    }
                                }.padding(.vertical, 12)
                            }
                            .coordinateSpace(name: "comicScroll")
                            .onPreferenceChange(CBZVisiblePageKey.self) { positions in
                                guard let nearest = positions.min(by: { abs($0.value - geometry.size.height / 2) < abs($1.value - geometry.size.height / 2) })?.key else { return }
                                pageIndex = nearest; emit(publication)
                            }
                            .onChange(of: navigationRequest) { _, request in consume(request, publication: publication, proxy: proxy) }
                            .onAppear { proxy.scrollTo(pageIndex, anchor: .center) }
                        }
                    } else {
                        let columns = columnCount(for: geometry.size.width)
                        let groups = (publication.pages.count + columns - 1) / columns
                        TabView(selection: $pageIndex) {
                            ForEach(0..<groups, id: \.self) { group in
                                pageView(publication, indices: columns == 2 ? Self.spread(pageCount: publication.pages.count, group: group) : [group], size: geometry.size)
                                    .tag(group * columns)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .onChange(of: pageIndex) { _, _ in emit(publication) }
                        .onChange(of: navigationRequest) { _, request in consume(request, publication: publication, proxy: nil) }
                    }
                } else if loadError == nil { ProgressView("Preparing comic…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: palette.background))
            .onAppear {
                viewport = geometry.size
                if let publication, pageLayout != .scroll {
                    pageIndex = CBZLoader.alignedPageIndex(pageIndex, pageCount: publication.pages.count, columns: columnCount(for: geometry.size.width))
                    emit(publication)
                }
            }
            .onChange(of: pageLayout) { _, newLayout in
                guard let publication else { return }
                if newLayout != .scroll {
                    pageIndex = CBZLoader.alignedPageIndex(pageIndex, pageCount: publication.pages.count, columns: columnCount(for: viewport.width))
                }
                emit(publication)
            }
            .onChange(of: geometry.size, initial: false) { _, newSize in
                let oldColumns = columnCount(for: viewport.width)
                let newColumns = columnCount(for: newSize.width)
                viewport = newSize
                if oldColumns != newColumns, let publication {
                    pageIndex = CBZLoader.alignedPageIndex(pageIndex, pageCount: publication.pages.count, columns: newColumns)
                }
                if let publication { emit(publication) }
            }
        }
        .overlay { if let loadError {
            ContentUnavailableView { Label("Couldn't open \(sourceFormat.displayName)", systemImage: "book.closed") } description: { Text(loadError) } actions: {
                Button("Try Again") { self.loadError = nil; loadID = UUID() }
            }.background(Color(uiColor: palette.background))
        } }
        .task(id: CBZSource(url: url, id: loadID)) {
            publication = nil; loadError = nil
            do {
                let loaded = try await sourceFormat == .cbr
                    ? CBRLoader.shared.open(url: url, bookID: bookID)
                    : CBZLoader.shared.open(url: url, bookID: bookID)
                try Task.checkCancellation()
                publication = loaded
                let restored = Int((min(max(progress.isFinite ? progress : 0, 0), 1) * Double(max(loaded.pages.count - 1, 0))).rounded())
                let columns = columnCount(for: viewport.width)
                pageIndex = pageLayout == .scroll ? restored : CBZLoader.alignedPageIndex(restored, pageCount: loaded.pages.count, columns: columns)
                emit(loaded)
            } catch is CancellationError { } catch { guard !Task.isCancelled else { return }; loadError = error.localizedDescription }
        }
        .contentShape(Rectangle())
        .onTapGesture { onContentTap() }
        .accessibilityAction(named: "Toggle reader controls") { onContentTap() }
    }

    private func pageView(_ publication: CBZPublication, indices: [Int], size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(indices, id: \.self) { index in
                CBZZoomablePage(url: publication.url(for: index), maxPixel: Int(max(size.width, size.height) * displayScale), cache: CBZImageCache.shared)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: max(size.height, 1))
    }

    private func consume(_ request: ReaderNavigationRequest?, publication: CBZPublication, proxy: ScrollViewProxy?) {
        guard let request, request.id != consumedRequest else { return }
        consumedRequest = request.id
        let per = columnCount(for: viewport.width)
        let maxStart = CBZLoader.lastGroupStart(pageCount: publication.pages.count, columns: per)
        switch request.command {
        case .previous: pageIndex = max(0, pageIndex - per)
        case .next: pageIndex = min(maxStart, pageIndex + per)
        case .seek(let value):
            let target = Int((min(max(value.isFinite ? value : 0, 0), 1) * Double(max(publication.pages.count - 1, 0))).rounded())
            pageIndex = pageLayout == .scroll ? target : CBZLoader.alignedPageIndex(target, pageCount: publication.pages.count, columns: per)
        case .chapter, .previousChapter, .nextChapter: break
        }
        proxy?.scrollTo(pageIndex, anchor: .top)
        emit(publication)
    }

    private func emit(_ publication: CBZPublication) {
        let count = publication.pages.count
        let columns = columnCount(for: viewport.width)
        let first = pageLayout == .scroll ? pageIndex : min(pageIndex, max(count - 1, 0))
        let last = min(first + columns - 1, max(count - 1, 0))
        let value = count <= 1 ? 0 : Double(first) / Double(count - 1)
        onNavigationStateChanged(ReaderNavigationState(progress: value, pageRange: (first + 1)...(last + 1), pageCount: count, canNavigatePrevious: first > 0, canNavigateNext: last < count - 1))
    }

    private static func spread(pageCount: Int, group: Int) -> [Int] { CBZLoader.spreadIndices(pageCount: pageCount, group: group) }
    private func columnCount(for width: CGFloat) -> Int {
        if pageLayout == .facingPages && width >= ReaderLayoutMetrics.spreadBreakpoint { return 2 }
        return 1
    }
    private struct CBZSource: Hashable { let url: URL; let id: UUID }
}

private struct CBZVisiblePageKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct CBZZoomablePage: UIViewRepresentable {
    let url: URL
    let maxPixel: Int
    let cache: CBZImageCache

    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView(); view.delegate = context.coordinator; view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.bouncesZoom = true; view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .clear; view.addSubview(context.coordinator.imageView)
        context.coordinator.scrollView = view
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        context.coordinator.layoutIfNeeded()
        guard context.coordinator.url != url || context.coordinator.maxPixel != maxPixel else { return }
        context.coordinator.load(url: url, maxPixel: maxPixel, cache: cache)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        var url: URL?
        var maxPixel = 0
        var loadID = UUID()
        var lastBounds = CGSize.zero

        override init() { super.init(); imageView.contentMode = .scaleAspectFit; imageView.isUserInteractionEnabled = false }

        func load(url: URL, maxPixel: Int, cache: CBZImageCache) {
            self.url = url; self.maxPixel = maxPixel
            imageView.image = nil
            let requestID = UUID(); loadID = requestID
            Task { [weak self] in
                let image = await cache.image(url: url, maxPixel: maxPixel)
                guard let self, self.loadID == requestID else { return }
                self.imageView.image = image
                self.layoutIfNeeded(force: true)
            }
        }

        func layoutIfNeeded(force: Bool = false) {
            guard let scrollView else { return }
            let size = scrollView.bounds.size
            guard size.width > 0, size.height > 0, force || size != lastBounds else { return }
            lastBounds = size
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    }
}
