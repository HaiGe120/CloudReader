import SwiftUI
import CloudReaderCore

struct BookCoverArtwork: View {
    @EnvironmentObject private var library: BookLibrary
    @State private var artwork: CGImage?
    let book: Book

    var body: some View {
        Color.clear
            .overlay {
                if let artwork {
                    ZStack {
                        #if os(macOS)
                        Color(nsColor: .controlBackgroundColor)
                        #else
                        Color(uiColor: .secondarySystemGroupedBackground)
                        #endif
                        Image(decorative: artwork, scale: 1)
                            .resizable()
                            .scaledToFit()
                    }
                    .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
            .task {
                guard book.format != .txt, let url = library.fileURL(for: book) else { return }
                let image = await BookCoverThumbnails.shared.thumbnail(at: url, format: book.format)
                if !Task.isCancelled { artwork = image }
            }
    }
}
