import SwiftUI

/// Shown in the Original view of a PowerPoint or Word document until its pages are rendered:
/// progress while rendering, the error with Try Again, or (on iPhone) where rendering happens.
struct RenderStatusView: View {
    let document: VLDocument

    private var service: PageRenderService { .shared }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if service.rendering.contains(document.id) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendering pages…").font(.headline)
                    Text("Making page images that look like the original \(document.kind == .pptx ? "slides" : "document").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else if let error = document.renderError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: DS.Space.s)
                Button("Try Again") { service.render(document) }
                    .buttonStyle(.borderedProminent)
            } else if !PageRenderService.isAvailable {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                Text("The original pages of PowerPoint and Word files are rendered on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                Text("The original pages haven't been rendered yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.s)
                Button("Render Pages") { service.render(document) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .cardStyle()
    }
}
