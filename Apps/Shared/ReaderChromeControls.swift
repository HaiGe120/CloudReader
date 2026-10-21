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
            if capabilities.supportsChapters, !state.chapterTitles.isEmpty {
                chapterControl
            }
            if capabilities.supportsPaging {
                pagingControls
            }
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
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
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
            Button { onNavigate(.previous) } label: {
                Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(!state.canNavigatePrevious)
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("reader.previous")
            Spacer()
            if capabilities.supportsChapters {
                Button { onNavigate(.previousChapter) } label: { Image(systemName: "backward.end") }
                    .disabled(state.chapterIndex.map { $0 == 0 } ?? true)
                    .accessibilityLabel("Previous chapter")
                Button { onNavigate(.nextChapter) } label: { Image(systemName: "forward.end") }
                    .disabled(state.chapterIndex.flatMap { index in state.chapterCount.map { index >= $0 - 1 } } ?? true)
                    .accessibilityLabel("Next chapter")
            }
            Spacer()
            Button { onNavigate(.next) } label: {
                Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(!state.canNavigateNext)
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("reader.next")
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 8)
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { scrubbedProgress ?? state.progress },
            set: { scrubbedProgress = $0 }
        )
    }
}
