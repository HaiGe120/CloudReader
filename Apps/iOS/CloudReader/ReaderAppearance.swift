import SwiftUI
import UIKit

enum ReaderPageLayout: String, CaseIterable, Identifiable, Equatable {
    case scroll
    case singlePage
    case facingPages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scroll: "Scrolling"
        case .singlePage: "One page"
        case .facingPages: "Two pages"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case sepia
    case dark
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .sepia: "Sepia"
        case .dark: "Dark"
        case .custom: "Custom"
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case systemSerif
    case systemSans
    case rounded
    case georgia
    case palatino
    case avenir
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemSerif: "New York"
        case .systemSans: "System Sans"
        case .rounded: "Rounded"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .avenir: "Avenir Next"
        case .monospaced: "Monospaced"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .systemSerif:
            return UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .systemSans:
            return UIFont.systemFont(ofSize: size)
        case .rounded:
            return UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .georgia:
            return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .palatino:
            return UIFont(name: "Palatino-Roman", size: size) ?? .systemFont(ofSize: size)
        case .avenir:
            return UIFont(name: "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

struct ReaderPalette {
    let background: UIColor
    let foreground: UIColor

    static func make(theme: ReaderTheme, customBackground: String, customForeground: String) -> ReaderPalette {
        switch theme {
        case .system:
            ReaderPalette(background: .systemBackground, foreground: .label)
        case .light:
            ReaderPalette(background: UIColor(red: 0.985, green: 0.982, blue: 0.968, alpha: 1), foreground: UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1))
        case .sepia:
            ReaderPalette(background: UIColor(red: 0.957, green: 0.925, blue: 0.858, alpha: 1), foreground: UIColor(red: 0.25, green: 0.20, blue: 0.15, alpha: 1))
        case .dark:
            ReaderPalette(background: UIColor(red: 0.075, green: 0.078, blue: 0.085, alpha: 1), foreground: UIColor(red: 0.88, green: 0.87, blue: 0.84, alpha: 1))
        case .custom:
            ReaderPalette(
                background: ReaderColor.uiColor(hex: customBackground),
                foreground: ReaderColor.uiColor(hex: customForeground)
            )
        }
    }
}

enum ReaderColor {
    static func uiColor(hex: String) -> UIColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(cleaned, radix: 16) else { return .white }
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    static func hex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

enum ReaderPagination {
    static func pages(from text: String, maximumCharacters: Int) -> [String] {
        let limit = max(1, maximumCharacters)
        var remainder = text
        var result: [String] = []

        while remainder.count > limit {
            let limitIndex = remainder.index(remainder.startIndex, offsetBy: limit)
            let whitespaceBoundary = remainder[..<limitIndex].lastIndex(where: \.isWhitespace)
            let boundary = whitespaceBoundary ?? limitIndex
            let page = String(remainder[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            let next = whitespaceBoundary.map { remainder.index(after: $0) } ?? boundary
            remainder = String(remainder[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !remainder.isEmpty { result.append(remainder) }
        return result.isEmpty ? [""] : result
    }

    static func pages(from text: String, width: CGFloat, height: CGFloat, font: UIFont) -> [String] {
        guard !text.isEmpty else { return [""] }
        let safeWidth = max(width, 40)
        let safeHeight = max(height, font.lineHeight)
        var remainder = text
        var result: [String] = []

        while !remainder.isEmpty {
            let upperBound = min(remainder.count, 4_000)
            var lower = 1
            var upper = upperBound
            var fittingCount = 1

            while lower <= upper {
                let candidateCount = (lower + upper) / 2
                let end = remainder.index(remainder.startIndex, offsetBy: candidateCount)
                let candidate = String(remainder[..<end])
                if measuredHeight(of: candidate, width: safeWidth, font: font) <= safeHeight {
                    fittingCount = candidateCount
                    lower = candidateCount + 1
                } else {
                    upper = candidateCount - 1
                }
            }

            if fittingCount >= remainder.count {
                result.append(remainder.trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            let fittingEnd = remainder.index(remainder.startIndex, offsetBy: min(fittingCount, remainder.count))
            var boundary = remainder[..<fittingEnd].lastIndex(where: \.isWhitespace)
            if let candidate = boundary {
                let distance = remainder.distance(from: remainder.startIndex, to: candidate)
                if distance < fittingCount * 4 / 5 { boundary = nil }
            }

            let pageEnd = boundary ?? fittingEnd
            let page = String(remainder[..<pageEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            let nextStart = boundary.map { remainder.index(after: $0) } ?? pageEnd
            remainder = String(remainder[nextStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result.isEmpty ? [""] : result
    }

    static func pageGroupCount(pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        return max((count + groupSize - 1) / groupSize, 1)
    }

    static func pageGroupIndex(progress: Double, pageCount: Int, pagesPerGroup: Int) -> Int {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let boundedProgress = min(max(progress, 0), 1)
        let pageIndex = min(Int(boundedProgress * Double(count)), count - 1)
        return pageIndex / groupSize
    }

    static func progress(pageGroupIndex: Int, pageCount: Int, pagesPerGroup: Int) -> Double {
        let count = max(pageCount, 1)
        let groupSize = max(pagesPerGroup, 1)
        let groupCount = pageGroupCount(pageCount: count, pagesPerGroup: groupSize)
        let boundedGroup = min(max(pageGroupIndex, 0), groupCount - 1)
        return Double(min(boundedGroup * groupSize, count - 1)) / Double(count)
    }

    static func measuredHeight(of text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let paragraph = paragraphStyle(for: font)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph],
            context: nil
        )
        return ceil(rect.height)
    }

    static func paragraphStyle(for font: UIFont) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = font.pointSize * 0.26
        paragraph.paragraphSpacing = font.pointSize * 0.55
        return paragraph
    }
}

struct ReaderAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.pageLayout") private var pageLayoutRaw = ReaderPageLayout.scroll.rawValue
    @AppStorage("reader.theme") private var themeRaw = ReaderTheme.system.rawValue
    @AppStorage("reader.font") private var fontRaw = ReaderFont.systemSerif.rawValue
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.customBackground") private var customBackground = "F8F4EB"
    @AppStorage("reader.customForeground") private var customForeground = "292621"

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Color(uiColor: ReaderColor.uiColor(hex: customBackground)) },
            set: { customBackground = ReaderColor.hex($0) }
        )
    }

    private var foregroundColor: Binding<Color> {
        Binding(
            get: { Color(uiColor: ReaderColor.uiColor(hex: customForeground)) },
            set: { customForeground = ReaderColor.hex($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page layout") {
                    HStack(spacing: 4) {
                        layoutButton(.scroll)
                        layoutButton(.singlePage)
                        layoutButton(.facingPages)
                    }
                    .padding(4)
                    .background(.quaternary, in: Capsule())
                    Text("Scrolling flows vertically. One-page mode turns horizontally. Two-page spreads use wide screens and fall back to one page on compact screens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Page color") {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    if themeRaw == ReaderTheme.custom.rawValue {
                        ColorPicker("Paper", selection: backgroundColor, supportsOpacity: false)
                        ColorPicker("Text", selection: foregroundColor, supportsOpacity: false)
                    }
                }

                Section("Typography") {
                    Picker("Font", selection: $fontRaw) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.title).tag(font.rawValue)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $fontSize, in: 15...30, step: 1)
                            .accessibilityLabel("Text size")
                    }
                    Text("PDF pages and EPUB appearance are controlled by their document reader. These typography settings apply to text books.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Reading Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func layoutButton(_ layout: ReaderPageLayout) -> some View {
        let selected = pageLayoutRaw == layout.rawValue
        return Button {
            pageLayoutRaw = layout.rawValue
        } label: {
            Text(layout.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    if selected {
                        Capsule().fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
