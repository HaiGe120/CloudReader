import SwiftUI

struct ReaderChromeControls: View {
    let state: ReaderNavigationState
    let capabilities: ReaderCapabilities
    let onNavigate: (ReaderNavigationCommand) -> Void

    @State private var scrubbedProgress: Double?

    private var pageDescription: String? {
        if let range = state.pageRange, let count = state.pageCount {
            if range.lowerBound == range.upperBound { return "Page \(range.lowerBound) of \(count)" }
            return "Pages \(range.lowerBound)–\(range.upperBound) of \(count)"
        }
        guard let count = state.pageCount else { return nil }
        return "\(count) pages"
    }

    var body: some View {
        VStack(spacing: 8) {
#if os(iOS)
            if capabilities.supportsChapters, !state.chapterTitles.isEmpty {
                HStack {
                    previousChapterButton
                    chapterControl
                    nextChapterButton
                }
                .buttonStyle(.plain)
            }
            HStack {
                if capabilities.supportsPaging { previousPageButton }
                progressControl
                if capabilities.supportsPaging { nextPageButton }
            }
            .buttonStyle(.plain)
#else
            if capabilities.supportsChapters, !state.chapterTitles.isEmpty {
                chapterControl
            }
            if capabilities.supportsPaging {
                pagingControls
            }
            progressControl
#endif
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
#if os(iOS)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
#else
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
#endif
    }

    private var progressControl: some View {
        HStack(spacing: 10) {
            Text(pageDescription ?? "\(Int(state.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("reader.pageStatus")
            Slider(value: progressBinding, in: 0...1) { editing in
                if !editing, let progress = scrubbedProgress {
                    onNavigate(.seek(progress))
                    scrubbedProgress = nil
                }
            }
            .accessibilityLabel("Reading progress")
            .accessibilityValue("\(Int((scrubbedProgress ?? state.progress) * 100)) percent")
        }
    }

    private var chapterControl: some View {
        Menu {
            ForEach(state.chapterTitles.indices, id: \.self) { index in
                Button {
                    onNavigate(.chapter(index))
                } label: {
                    if index == state.chapterIndex {
                        Label(state.chapterTitles[index], systemImage: "checkmark")
                    } else {
                        Text(state.chapterTitles[index])
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentChapterTitle).lineLimit(1)
                if let index = state.chapterIndex, let count = state.chapterCount {
                    Text("\(index + 1) of \(count)").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
#if os(iOS)
            .frame(minHeight: 44)
#endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Chapters")
        .accessibilityValue(currentChapterTitle)
        .accessibilityIdentifier("reader.chapters")
    }

    private var currentChapterTitle: String {
        guard let index = state.chapterIndex, state.chapterTitles.indices.contains(index) else {
            return "Choose chapter"
        }
        return state.chapterTitles[index]
    }

    private var pagingControls: some View {
        HStack {
            previousPageButton
            Spacer()
            if capabilities.supportsChapters {
                previousChapterButton
                nextChapterButton
            }
            Spacer()
            nextPageButton
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 8)
    }

    private var previousPageButton: some View {
        Button { onNavigate(.previous) } label: { navigationIcon("chevron.left") }
            .disabled(!state.canNavigatePrevious)
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("reader.previous")
    }

    private var nextPageButton: some View {
        Button { onNavigate(.next) } label: { navigationIcon("chevron.right") }
            .disabled(!state.canNavigateNext)
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("reader.next")
    }

    private var previousChapterButton: some View {
        Button { onNavigate(.previousChapter) } label: { navigationIcon("backward.end") }
            .disabled(state.chapterIndex.map { $0 == 0 } ?? true)
            .accessibilityLabel("Previous chapter")
    }

    private var nextChapterButton: some View {
        Button { onNavigate(.nextChapter) } label: { navigationIcon("forward.end") }
            .disabled(state.chapterIndex.flatMap { index in state.chapterCount.map { index >= $0 - 1 } } ?? true)
            .accessibilityLabel("Next chapter")
    }

    private func navigationIcon(_ name: String) -> some View {
        Image(systemName: name)
#if os(iOS)
            .font(.system(size: 15, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
#endif
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { scrubbedProgress ?? state.progress },
            set: { scrubbedProgress = $0 }
        )
    }
}
