import Foundation

/// Word files don't store laid-out pages, so pages are reconstructed from:
/// 1. `<w:lastRenderedPageBreak/>` markers Word writes on save (where pages really fell),
/// 2. explicit page breaks (`<w:br w:type="page"/>`, `<w:pageBreakBefore/>`),
/// 3. otherwise, roughly one printed page of text (~`charsPerPage`) at paragraph boundaries.
/// Tables and images stay on the page where they appear.
enum DOCXExtractor {

    static let charsPerPage = 2800

    static func extract(from url: URL) throws -> [ExtractedPage] {
        let reader: ZIPReader
        do { reader = try ZIPReader(url: url) } catch { throw ImportError.archiveOpenFailed }

        guard let docData = reader.extract(path: "word/document.xml") else {
            throw ImportError.archiveOpenFailed
        }

        let parser = DocxBlockParser.parse(docData)
        let rels = reader.extract(path: "word/_rels/document.xml.rels").map(parseImageRelationships) ?? [:]

        let pages = paginate(parser.blocks, hasBreaks: parser.sawPageBreak)

        return pages.enumerated().map { index, blocks in
            var body: [String] = [], tables: [String] = [], images: [Data] = []
            for block in blocks {
                switch block {
                case .paragraph(let text): body.append(text)
                case .tableRow(let text):  tables.append(text)
                case .image(let rid):
                    guard let target = rels[rid] else { continue }
                    let path = "word/" + target.replacingOccurrences(of: "../", with: "")
                    if let raw = reader.extract(path: path), let jpeg = ImageCoding.jpeg(from: raw, minSide: 32) {
                        images.append(jpeg)
                    }
                case .pageBreak: break
                }
            }
            return ExtractedPage(
                index: index,
                bodyText: body.joined(separator: "\n"),
                tablesText: tables.joined(separator: "\n"),
                imageData: images
            )
        }
    }

    private static func paginate(_ blocks: [DocxBlock], hasBreaks: Bool) -> [[DocxBlock]] {
        var pages: [[DocxBlock]] = [[]]
        var chars = 0

        func newPage() {
            guard !(pages.last?.isEmpty ?? true) else { return }  // collapse duplicate breaks
            pages.append([])
            chars = 0
        }

        for block in blocks {
            switch block {
            case .pageBreak:
                if hasBreaks { newPage() }
            case .paragraph(let text), .tableRow(let text):
                if !hasBreaks, chars > 0, chars + text.count > charsPerPage { newPage() }
                pages[pages.count - 1].append(block)
                chars += text.count
            case .image:
                pages[pages.count - 1].append(block)
            }
        }
        return pages.filter { !$0.isEmpty }.isEmpty ? [[]] : pages.filter { !$0.isEmpty }
    }
}

// MARK: - Parser

enum DocxBlock {
    case paragraph(String)
    case tableRow(String)
    case image(rid: String)
    case pageBreak
}

/// Walks `word/document.xml` in order and emits paragraphs, table rows, images and page breaks.
final class DocxBlockParser: NSObject, XMLParserDelegate {

    private(set) var blocks: [DocxBlock] = []
    private(set) var sawPageBreak = false

    private var paragraph = ""
    private var inText = false
    private var tableDepth = 0
    private var cellParagraphs: [String] = []
    private var rowCells: [String] = []

    static func parse(_ data: Data) -> DocxBlockParser {
        let p = DocxBlockParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    /// Ends the text collected so far as its own paragraph (used when a break splits a paragraph).
    private func flushParagraph() {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        paragraph = ""
        guard !text.isEmpty else { return }
        if tableDepth > 0 { cellParagraphs.append(text) } else { blocks.append(.paragraph(text)) }
    }

    private func pageBreak() {
        guard tableDepth == 0 else { return }  // keep tables on one page
        flushParagraph()
        blocks.append(.pageBreak)
        sawPageBreak = true
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName _: String?, attributes: [String: String] = [:]) {
        switch element {
        case "w:t":                     inText = true
        case "w:tab":                   paragraph += " "
        case "w:br" where attributes["w:type"] == "page": pageBreak()
        case "w:br":                    paragraph += " "
        case "w:lastRenderedPageBreak": pageBreak()
        case "w:pageBreakBefore" where attributes["w:val"].map({ $0 != "0" && $0 != "false" }) ?? true:
            pageBreak()
        case "w:tbl":                   tableDepth += 1
        case "w:tr" where tableDepth == 1: rowCells = []
        case "w:tc" where tableDepth == 1: cellParagraphs = []
        case "a:blip":
            if let rid = attributes["r:embed"] { blocks.append(.image(rid: rid)) }
        case "v:imagedata":
            if let rid = attributes["r:id"] { blocks.append(.image(rid: rid)) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName _: String?) {
        switch element {
        case "w:t":  inText = false
        case "w:p":  flushParagraph()
        case "w:tc" where tableDepth == 1:
            rowCells.append(cellParagraphs.joined(separator: " "))
        case "w:tr" where tableDepth == 1:
            if rowCells.contains(where: { !$0.isEmpty }) {
                blocks.append(.tableRow(rowCells.joined(separator: "\t")))
            }
        case "w:tbl": tableDepth -= 1
        default: break
        }
    }
}
