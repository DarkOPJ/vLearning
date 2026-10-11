import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum PPTXExtractor {

    static func extract(from url: URL) throws -> [ExtractedPage] {
        let reader: ZIPReader
        do { reader = try ZIPReader(url: url) } catch { throw ImportError.archiveOpenFailed }

        let slideEntries = reader.paths
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }

        var pages: [ExtractedPage] = []

        for (idx, slidePath) in slideEntries.enumerated() {
            guard let slideData = reader.extract(path: slidePath) else { continue }
            let textParser = OOXMLTextParser.parse(slideData)

            // Resolve image rIds → media bytes
            let relsPath = "ppt/slides/_rels/\(URL(fileURLWithPath: slidePath).lastPathComponent).rels"
            var imageData: [Data] = []
            if let relsData = reader.extract(path: relsPath) {
                let rels = parseImageRelationships(from: relsData)
                for rid in textParser.imageRids {
                    guard let target = rels[rid] else { continue }
                    let mediaPath = resolveRelativePath(base: "ppt/slides/", relative: target)
                    if let imgData = reader.extract(path: mediaPath) {
                        imageData.append(toJPEG(imgData) ?? imgData)
                    }
                }
            }

            // Speaker notes
            let notesSlidePath = "ppt/notesSlides/notesSlide\(slideNumber(slidePath)).xml"
            var notesText = ""
            if let notesData = reader.extract(path: notesSlidePath) {
                notesText = OOXMLTextParser.parse(notesData).bodyText
            }

            pages.append(ExtractedPage(
                index: idx,
                bodyText: textParser.bodyText,
                notesText: notesText,
                tablesText: textParser.tableText,
                imageData: imageData,
                isLikelyScanned: false
            ))
        }

        return pages
    }

    // MARK: - Helpers

    private static func slideNumber(_ path: String) -> Int {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Int(name.replacingOccurrences(of: "slide", with: "")) ?? 0
    }

    private static func resolveRelativePath(base: String, relative: String) -> String {
        var components = base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            if part == ".." { components.removeLast() }
            else { components.append(part) }
        }
        return components.joined(separator: "/")
    }

    private static func toJPEG(_ data: Data) -> Data? {
        #if os(iOS)
        UIImage(data: data)?.jpegData(compressionQuality: 0.85)
        #else
        guard let img = NSImage(data: data),
              let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.85)])
        #endif
    }
}
