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
    parseRelationships(from: data).filter { $0.value.type.hasSuffix("/image") }.mapValues(\.target)
}

/// Parses a `.rels` file into rId → (relationship type URI, target path).
func parseRelationships(from data: Data) -> [String: (type: String, target: String)] {
    let p = RelsParser()
    let x = XMLParser(data: data)
    x.delegate = p
    x.parse()
    return p.rels
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var rels: [String: (type: String, target: String)] = [:]

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
              let type_  = attributes["Type"]
        else { return }
        rels[id] = (type_, target)
    }
}
