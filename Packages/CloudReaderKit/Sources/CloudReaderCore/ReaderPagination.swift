import Foundation

/// Stable preference values shared by the Apple readers.
public enum ReaderPageLayout: String, CaseIterable, Identifiable, Equatable, Sendable {
    case scroll
    case singlePage
    case facingPages

    public var id: String { rawValue }
}

public enum ReaderTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case sepia
    case dark
    case custom

    public var id: String { rawValue }
}

public enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case systemSerif
    case systemSans
    case rounded
    case georgia
    case palatino
    case avenir
    case monospaced

    public var id: String { rawValue }
}

/// Pure character pagination and page/spread progress calculations.
/// Native font measurement remains supplied by each platform at the call site.
public enum ReaderPaginationPolicy {
    public static func pages(from text: String, maximumCharacters: Int) -> [String] {
        paginate(from: text, maximumCharacters: maximumCharacters, fits: nil)
    }

    public static func pages(from text: String, fits: @escaping (String) -> Bool, shouldCancel: @escaping () -> Bool = { false }) -> [String] {
        paginate(from: text, maximumCharacters: 4_000, fits: fits, shouldCancel: shouldCancel)
    }

    private static func paginate(
        from text: String,
        maximumCharacters: Int,
        fits: ((String) -> Bool)?,
        shouldCancel: () -> Bool = { false }
    ) -> [String] {
        guard !text.isEmpty else { return [""] }
        let limit = max(maximumCharacters, 1)
        var start = text.startIndex
        var remainingCount = text.count
        var result: [String] = []

        while remainingCount > 0 {
            if shouldCancel() { return [] }
            var lower = 1
            var upper = min(remainingCount, limit)
            var fittingCount = 1
            while lower <= upper {
                let candidateCount = (lower + upper) / 2
                let end = text.index(start, offsetBy: candidateCount)
                let candidate = String(text[start..<end])
                if fits?(candidate) ?? true {
                    fittingCount = candidateCount
                    lower = candidateCount + 1
                } else {
                    upper = candidateCount - 1
                }
            }

            if fittingCount >= remainingCount {
                result.append(String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            let fittingEnd = text.index(start, offsetBy: fittingCount)
            var boundary = text[start..<fittingEnd].lastIndex(where: \.isWhitespace)
            if let candidate = boundary, text.distance(from: start, to: candidate) < fittingCount * 4 / 5 {
                boundary = nil
            }
            let pageEnd = boundary ?? fittingEnd
            let page = String(text[start..<pageEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            let next = boundary.map { text.index(after: $0) } ?? pageEnd
            remainingCount -= text.distance(from: start, to: next)
            start = next
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
                remainingCount -= 1
            }
        }
        return result.isEmpty ? [""] : result
    }

    public static func pageGroupCount(pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        return max((count + groupSize - 1) / groupSize, 1)
    }

    public static func pageGroupIndex(progress: Double, pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let boundedProgress = min(max(progress, 0), 1)
        // Fractions stored for an exact page can multiply back just below an integer.
        let pageIndex = min(Int((boundedProgress * Double(count) + 1e-9).rounded(.down)), count - 1)
        return pageIndex / groupSize
    }

    public static func progress(pageGroupIndex: Int, pageCount: Int, pagesPerGroup: Int) -> Double {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let groupCount = pageGroupCount(pageCount: count, pagesPerGroup: groupSize)
        let boundedGroup = min(max(pageGroupIndex, 0), groupCount - 1)
        return Double(min(boundedGroup * groupSize, count - 1)) / Double(count)
    }
}
