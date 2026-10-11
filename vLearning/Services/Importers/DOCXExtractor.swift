import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum DOCXExtractor {

    private static let paragraphsPerPage = 40

    static func extract(from url: URL) throws -> [ExtractedPage] {
        let reader: ZIPReader
        do { reader = try ZIPReader(url: url) } catch { throw ImportError.archiveOpenFailed }

        guard let docData = reader.extract(path: "word/document.xml") else {
            throw ImportError.archiveOpenFailed
        }

        let textParser = OOXMLTextParser.parse(docData)
        let allBody   = textParser.bodyText
        let allTables = textParser.tableText

        // Resolve image rIds → media bytes
        var allImageData: [Data] = []
        if let relsData = reader.extract(path: "word/_rels/document.xml.rels") {
            let rels = parseImageRelationships(from: relsData)
            for rid in textParser.imageRids {
                guard let target = rels[rid] else { continue }
                let mediaPath = "word/" + target.replacingOccurrences(of: "../", with: "")
                if let imgData = reader.extract(path: mediaPath) {
                    allImageData.append(toJPEG(imgData) ?? imgData)
                }
            }
        }

        // Split into pages on explicit page breaks; fall back to paragraph chunking
        let breakIndices = parseDocxPageBreakIndices(from: docData)
        let paragraphs   = allBody.components(separatedBy: "\n").filter { !$0.isEmpty }

        let pageTexts: [[String]]
        if breakIndices.isEmpty {
            pageTexts = stride(from: 0, to: paragraphs.count, by: paragraphsPerPage).map {
                Array(paragraphs[$0 ..< min($0 + paragraphsPerPage, paragraphs.count)])
            }
        } else {
            var chunks: [[String]] = []
            var start = 0
            for breakAt in breakIndices {
                let end = min(breakAt + 1, paragraphs.count)
                chunks.append(Array(paragraphs[start ..< end]))
                start = end
            }
            if start < paragraphs.count { chunks.append(Array(paragraphs[start...])) }
            pageTexts = chunks
        }

        let totalPages    = max(pageTexts.count, 1)
        let imagesPerPage = allImageData.isEmpty ? 0 : max(1, allImageData.count / totalPages)

        return pageTexts.isEmpty
            ? [ExtractedPage(index: 0, bodyText: allBody, notesText: "", tablesText: allTables,
                             imageData: allImageData, isLikelyScanned: false)]
            : pageTexts.enumerated().map { idx, paras in
                let start  = idx * imagesPerPage
                let end    = min(start + imagesPerPage, allImageData.count)
                let imgs   = start < allImageData.count ? Array(allImageData[start ..< end]) : []
                let tables = idx == pageTexts.count - 1 ? allTables : ""
                return ExtractedPage(
                    index: idx,
                    bodyText: paras.joined(separator: "\n"),
                    notesText: "",
                    tablesText: tables,
                    imageData: imgs,
                    isLikelyScanned: false
                )
            }
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
