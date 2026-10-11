import SwiftUI

/// Loads an image file from disk off the main thread, downsampled to `maxPixelSize`.
struct StoredImage: View {
    let url: URL
    var maxPixelSize: Int = 600
    var contentMode: ContentMode = .fit

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: url) {
            let url = url, size = maxPixelSize
            let loaded = await Task.detached(priority: .utility) {
                ImageCoding.thumbnail(at: url, maxPixelSize: size)
            }.value
            image = loaded
            failed = loaded == nil
        }
    }
}
