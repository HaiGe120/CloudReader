import CloudReaderCore
import Foundation

/// The interactions and presentation features a concrete reader adapter can provide.
struct ReaderCapabilities: Equatable, Sendable {
    let supportsTypography: Bool
    let supportsSelection: Bool
    let supportsSelectedTextAI: Bool
    let supportsChapters: Bool
    let supportsPaging: Bool
    let supportsSpreads: Bool

    static let reflowable = ReaderCapabilities(
        supportsTypography: true,
        supportsSelection: true,
        supportsSelectedTextAI: true,
        supportsChapters: true,
        supportsPaging: true,
        supportsSpreads: true
    )
    static let text = ReaderCapabilities(
        supportsTypography: true,
        supportsSelection: true,
        supportsSelectedTextAI: true,
        supportsChapters: false,
        supportsPaging: true,
        supportsSpreads: true
    )
    static let pdf = ReaderCapabilities(
        supportsTypography: false,
        supportsSelection: true,
        supportsSelectedTextAI: true,
        supportsChapters: false,
        supportsPaging: true,
        supportsSpreads: true
    )
    static let comic = ReaderCapabilities(
        supportsTypography: false,
        supportsSelection: false,
        supportsSelectedTextAI: false,
        supportsChapters: false,
        supportsPaging: true,
        supportsSpreads: true
    )
}

/// Layout values are resolved from the reader's measured viewport, not the device class.
struct ReaderLayoutMetrics: Equatable, Sendable {
    static let spreadBreakpoint: CGFloat = 700
    static let maximumProseWidth: CGFloat = 780
    static let spreadGutter: CGFloat = 28

    let viewport: CGSize
    let effectiveColumnCount: Int
    let horizontalMargin: CGFloat
    let gutter: CGFloat
    let maximumProseWidth: CGFloat
    let font: ReaderFont
    let fontSize: CGFloat

    static func resolve(
        viewport: CGSize,
        pageLayout: ReaderPageLayout,
        font: ReaderFont,
        fontSize: CGFloat
    ) -> ReaderLayoutMetrics {
        let width = max(viewport.width, 0)
        let margin = min(max(width * 0.045, 22), 42)
        let columns = pageLayout == .facingPages && width >= spreadBreakpoint ? 2 : 1
        return ReaderLayoutMetrics(
            viewport: viewport,
            effectiveColumnCount: columns,
            horizontalMargin: margin,
            gutter: columns == 2 ? spreadGutter : 0,
            maximumProseWidth: maximumProseWidth,
            font: font,
            fontSize: fontSize
        )
    }
}

/// A renderer-neutral snapshot of current location and available navigation.
struct ReaderNavigationState: Equatable, Sendable {
    let progress: Double
    let pageRange: ClosedRange<Int>?
    let pageCount: Int?
    let chapterIndex: Int?
    let chapterCount: Int?
    let chapterTitles: [String]
    let canNavigatePrevious: Bool
    let canNavigateNext: Bool

    init(
        progress: Double,
        pageRange: ClosedRange<Int>? = nil,
        pageCount: Int? = nil,
        chapterIndex: Int? = nil,
        chapterCount: Int? = nil,
        chapterTitles: [String] = [],
        canNavigatePrevious: Bool,
        canNavigateNext: Bool
    ) {
        self.progress = min(max(progress, 0), 1)
        self.pageRange = pageRange
        self.pageCount = pageCount
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.chapterTitles = chapterTitles
        self.canNavigatePrevious = canNavigatePrevious
        self.canNavigateNext = canNavigateNext
    }
}

enum ReaderNavigationCommand: Equatable, Sendable {
    case previous
    case next
    case previousChapter
    case nextChapter
    case chapter(Int)
    case seek(Double)
}

/// Request identifiers make adapter consumption idempotent across SwiftUI updates.
struct ReaderNavigationRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    let command: ReaderNavigationCommand

    init(id: UUID = UUID(), command: ReaderNavigationCommand) {
        self.id = id
        self.command = command
    }
}

struct PreparedHTMLChapter: Equatable, Sendable {
    let path: String
    let title: String
}

/// A disposable local preparation result; never persisted or included in sync records.
enum PreparedPublication {
    case text(String)
    case localHTML(rootURL: URL, chapters: [PreparedHTMLChapter], mediaTypes: [String: String])
    case pdf(URL)
    case imagePages([URL])
}
