import Foundation

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
            let text = OOXMLTextParser.parse(slideData)

            let slideName = URL(fileURLWithPath: slidePath).lastPathComponent
            let rels = reader.extract(path: "ppt/slides/_rels/\(slideName).rels").map(parseRelationships) ?? [:]

            // Images, in the order they appear on the slide (each picture once).
            var images: [Data] = []
            var usedTargets = Set<String>()
            for rid in text.imageRids {
                guard let rel = rels[rid], rel.type.hasSuffix("/image") else { continue }
                let mediaPath = resolveRelativePath(base: "ppt/slides/", relative: rel.target)
                guard usedTargets.insert(mediaPath).inserted,
                      let raw = reader.extract(path: mediaPath),
                      let jpeg = ImageCoding.jpeg(from: raw, minSide: 32)
                else { continue }
                images.append(jpeg)
            }

            // Speaker notes: follow the slide's notesSlide relationship (file numbers don't always match).
            var notesText = ""
            if let notesRel = rels.values.first(where: { $0.type.hasSuffix("/notesSlide") }),
               let notesData = reader.extract(path: resolveRelativePath(base: "ppt/slides/", relative: notesRel.target)) {
                notesText = cleanNotes(OOXMLTextParser.parse(notesData).bodyText, slideNumber: idx + 1)
            }

            pages.append(ExtractedPage(
                index: idx,
                bodyText: text.bodyText,
                notesText: notesText,
                tablesText: text.tableText,
                imageData: images
            ))
        }

        return pages
    }

    // MARK: - Helpers

    private static func slideNumber(_ path: String) -> Int {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return Int(name.replacingOccurrences(of: "slide", with: "")) ?? 0
    }

    /// Notes pages repeat the slide number in a placeholder; drop that lone line.
    private static func cleanNotes(_ text: String, slideNumber: Int) -> String {
        text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != String(slideNumber) }
            .joined(separator: "\n")
    }

    private static func resolveRelativePath(base: String, relative: String) -> String {
        if relative.hasPrefix("/") { return String(relative.dropFirst()) }
        var components = base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else if part != "." { components.append(part) }
        }
        return components.joined(separator: "/")
    }
}
