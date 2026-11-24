import SwiftUI
import Translation

enum ReaderTranslationTarget {
    static let enabledKey = "reader.translateEnglishSelection"
    static let key = "reader.translationTargetLanguage"
    static let automatic = "automatic"
    static let english = Locale.Language(identifier: "en")

    static func initializePreference(in defaults: UserDefaults) {
        guard defaults.string(forKey: key) == nil else { return }
        defaults.set(defaults.bool(forKey: enabledKey) ? "zh-Hans" : automatic, forKey: key)
    }

    static func language(for identifier: String) -> Locale.Language? {
        identifier == automatic ? nil : Locale.Language(identifier: identifier)
    }

    static func identifier(for language: Locale.Language) -> String {
        if language.languageCode?.identifier == "zh" {
            for script in ["zh-Hans", "zh-Hant"] where language.isEquivalent(to: Locale.Language(identifier: script)) {
                return script
            }
        }
        return language.minimalIdentifier
    }

    static func supportedIdentifiers() async -> [String] {
        let availability = LanguageAvailability()
        var identifiers: Set<String> = []
        for language in await availability.supportedLanguages where language.languageCode != english.languageCode {
            guard !Task.isCancelled else { return [] }
            switch await availability.status(from: english, to: language) {
            case .installed, .supported: identifiers.insert(identifier(for: language))
            default: continue
            }
        }
        return Array(identifiers)
    }
}

extension EnvironmentValues {
    @Entry var readerTranslationLanguages: () async -> [String] = ReaderTranslationTarget.supportedIdentifiers
}

struct ReaderTranslationSettings: View {
    @Environment(\.locale) private var locale
    @Environment(\.readerTranslationLanguages) private var loadLanguages
    @AppStorage(ReaderTranslationTarget.enabledKey) private var enabled = false
    @AppStorage(ReaderTranslationTarget.key) private var target = ReaderTranslationTarget.automatic
    @State private var identifiers: [String]?

    var body: some View {
        Toggle("Translate selected English words", isOn: $enabled)
        if enabled {
            Picker("Translate to", selection: $target) {
                Text("System preference").tag(ReaderTranslationTarget.automatic)
                if target != ReaderTranslationTarget.automatic, !(identifiers ?? []).contains(target) {
                    Text(name(target)).tag(target).disabled(true)
                }
                ForEach((identifiers ?? []).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }, id: \.self) { identifier in
                    Text(name(identifier)).tag(identifier)
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
            .accessibilityIdentifier("translation.target")
            .disabled(identifiers == nil)
            .task {
                let supported = await loadLanguages()
                if !Task.isCancelled { identifiers = supported }
            }
            if identifiers == nil {
                ProgressView("Loading languages…").controlSize(.small)
            } else if identifiers?.isEmpty == true {
                Text("Apple Translation has no languages available on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func name(_ identifier: String) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct ReaderWordTranslation: View {
    let word: String
    let target: Locale.Language?
    @Environment(\.locale) private var locale
    @State private var result: TranslationSession.Response?
    @State private var failure: String?
    @State private var dismissed = false

    static func englishWord(_ text: String) -> String? {
        guard text.utf8.count <= 120 else { return nil }
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard word.range(of: #"^[A-Za-z]+(?:['’\-][A-Za-z]+)*$"#, options: .regularExpression) != nil else { return nil }
        return word
    }

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(word).font(.headline)
                    if let language = result?.targetLanguage ?? target {
                        let identifier = ReaderTranslationTarget.identifier(for: language)
                        Text(locale.localizedString(forIdentifier: identifier) ?? identifier)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("reader.translation.language")
                    }
                    if let result { Text(result.targetText).font(.body) }
                    else if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
                    else { ProgressView("Translating…").controlSize(.small) }
                }
                Button { dismissed = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss translation")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.translation")
            .translationTask(source: ReaderTranslationTarget.english, target: target) { session in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let response = try await session.translate(word)
                    try Task.checkCancellation()
                    result = response
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
        }
    }
}

/// Position the card near the selection and keep it inside the reading surface.
struct SelectionTranslationOverlay: View {
    let word: String
    let selectionRect: CGRect?
    @AppStorage(ReaderTranslationTarget.key) private var targetID = ReaderTranslationTarget.automatic
    @State private var cardSize = CGSize(width: 180, height: 70)

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let selection = selectionRect?.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let halfWidth = cardSize.width / 2
            let halfHeight = cardSize.height / 2
            let centerX = selection?.midX ?? frame.width / 2
            #if os(iOS)
            let gap: CGFloat = 58 // Leave room for the native text-selection menu.
            #else
            let gap: CGFloat = 14
            #endif
            let below = (selection?.maxY ?? frame.height / 2) + gap + halfHeight
            let above = (selection?.minY ?? frame.height / 2) - gap - halfHeight
            ReaderWordTranslation(word: word, target: ReaderTranslationTarget.language(for: targetID))
                .id(targetID)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: min(300, max(1, frame.width - 24)), alignment: .center)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .position(x: min(max(centerX, halfWidth + 8), frame.width - halfWidth - 8),
                          y: min(max(below + halfHeight < frame.height - 68 ? below : above, halfHeight + 8),
                                 frame.height - halfHeight - 8))
        }
    }
}
