import Foundation

// MARK: - Text extractor (PPTX / DOCX)

/// SAX parser that walks OOXML (DrawingML / WordprocessingML) and collects
/// body text, table text, and the relationship IDs of embedded images.
///
/// Both PPTX and DOCX use the same DrawingML `<a:t>` text run element;
/// DOCX additionally uses `<w:t>`. This single parser handles both.
final class OOXMLTextParser: NSObject, XMLParserDelegate {

    private var bodyLines:  [String] = []
    private var tableLines: [String] = []
    private var currentPara   = ""
    private var currentRun    = ""
    private var inTextElement = false

    // Table tracking
    private var tableDepth  = 0
    private var rowCells:    [String] = []
    private var cellParas:   [String] = []
    private var inCell       = false

    // Image relationship IDs collected from <a:blip r:embed="rIdN"/>
    private(set) var imageRids: [String] = []

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        switch element {
        case "a:tbl", "w:tbl":
            tableDepth += 1
        case "a:tr", "w:tr" where tableDepth > 0:
            rowCells = []
        case "a:tc", "w:tc" where tableDepth > 0:
            inCell = true
            cellParas = []
        case "a:p", "w:p":
            currentPara = ""
        case "a:t", "w:t":
            inTextElement = true
            currentRun = ""
        case "a:blip":
            if let rid = attributes["r:embed"] { imageRids.append(rid) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement { currentRun += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement element: String,
        namespaceURI: String?,
        qualifiedName _: String?
    ) {
        switch element {

        case "a:t", "w:t":
            inTextElement = false
            currentPara += currentRun
            currentRun = ""

        case "a:p", "w:p":
            let para = currentPara.trimmingCharacters(in: .whitespacesAndNewlines)
            if !para.isEmpty {
                if inCell {
                    cellParas.append(para)
                } else if tableDepth > 0 {
                    tableLines.append(para)
                } else {
                    bodyLines.append(para)
                }
            }
            currentPara = ""

        case "a:tc", "w:tc" where tableDepth > 0:
            inCell = false
            let cellText = cellParas.joined(separator: " ")
            rowCells.append(cellText)

        case "a:tr", "w:tr" where tableDepth > 0:
            if !rowCells.isEmpty {
                tableLines.append(rowCells.joined(separator: "\t"))
            }
            rowCells = []

        case "a:tbl", "w:tbl":
            tableDepth -= 1

        default:
            break
        }
    }

    // MARK: - Results

    var bodyText:  String { bodyLines.joined(separator: "\n") }
    var tableText: String { tableLines.joined(separator: "\n") }

    // MARK: - Factory

    static func parse(_ data: Data) -> OOXMLTextParser {
        let p = OOXMLTextParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }
}

// MARK: - Relationships parser (PPTX/DOCX _rels/*.rels)

/// Parses a `.rels` file and returns the map rId → target path for image relationships.
func parseImageRelationships(from data: Data) -> [String: String] {
    let p = RelsParser()
    let x = XMLParser(data: data)
    x.delegate = p
    x.parse()
    return p.imageRels
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var imageRels: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        guard element == "Relationship",
              let id     = attributes["Id"],
              let target = attributes["Target"],
              let type_  = attributes["Type"],
              type_.hasSuffix("/image")
        else { return }
        imageRels[id] = target
    }
}

// MARK: - DOCX page-break detection

/// Returns the positions of explicit page breaks (`<w:br w:type="page"/>`) in
/// the flat list of DOCX paragraph elements, so the extractor can split them.
func parseDocxPageBreakIndices(from data: Data) -> [Int] {
    let p = DocxBreakParser()
    let x = XMLParser(data: data)
    x.delegate = p
    x.parse()
    return p.breakIndices
}

private final class DocxBreakParser: NSObject, XMLParserDelegate {
    var breakIndices: [Int] = []
    private var paragraphIndex = 0
    private var inPara = false
    private var hadBreak = false

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attrs: [String: String] = [:]) {
        switch element {
        case "w:p":
            inPara = true
            hadBreak = false
        case "w:br" where inPara:
            if attrs["w:type"] == "page" { hadBreak = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName _: String?) {
        if element == "w:p" {
            if hadBreak { breakIndices.append(paragraphIndex) }
            paragraphIndex += 1
            inPara = false
        }
    }
}
