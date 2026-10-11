import Foundation
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum PDFExtractor {

    static func extract(from url: URL) throws -> [ExtractedPage] {
        guard let doc = PDFDocument(url: url) else { throw ImportError.pdfLoadFailed }

        var pages: [ExtractedPage] = []

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }

            let raw = page.string ?? ""
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let isScanned = body.count < ExtractedPage.scannedThreshold

            // Render the page to JPEG for the image picker.
            // Scanned pages: the render IS the content.
            // Digital pages: the render lets the user inspect embedded graphics.
            var images: [Data] = []
            if let jpegData = renderPage(page) {
                images.append(jpegData)
            }

            pages.append(ExtractedPage(
                index: i,
                bodyText: body,
                notesText: "",
                tablesText: "",
                imageData: images,
                isLikelyScanned: isScanned
            ))
        }

        return pages
    }

    // MARK: - Render

    private static let renderWidth: CGFloat = 1500

    private static func renderPage(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale  = renderWidth / bounds.width
        let size   = CGSize(width: renderWidth, height: bounds.height * scale)

        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: ctx.cgContext)
        }
        return image.jpegData(compressionQuality: 0.85)

        #else
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .cropBox, to: ctx)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.85)])
        #endif
    }
}
