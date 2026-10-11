import Foundation
import PDFKit
#if os(macOS)
import AppKit
#endif

/// Renders PowerPoint and Word documents to page images for the "Original" view (Mac only).
/// The file is converted to PDF with LibreOffice when it's installed, otherwise with Keynote or Pages.
/// One document renders at a time.
@MainActor
@Observable
final class PageRenderService {

    static let shared = PageRenderService()

    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Documents being rendered right now (or waiting to).
    private(set) var rendering: Set<UUID> = []
    private var chain: Task<Void, Never>?

    private init() {}

    /// PowerPoint/Word document with no rendered pages yet (and no failed attempt to show).
    func needsRender(_ doc: VLDocument) -> Bool {
        Self.isAvailable && doc.kind != .pdf && doc.renderedPagePaths.isEmpty
            && doc.renderError == nil && !rendering.contains(doc.id)
    }

    func render(_ doc: VLDocument) {
        #if os(macOS)
        guard doc.kind != .pdf, !rendering.contains(doc.id) else { return }
        rendering.insert(doc.id)
        doc.renderError = nil
        let id = doc.id, kind = doc.kind
        let previous = chain
        chain = Task {
            await previous?.value
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OfficeRenderer.render(docId: id, kind: kind)
                }.value
                if doc.modelContext != nil { apply(result, to: doc) }
            } catch {
                if doc.modelContext != nil { doc.renderError = error.localizedDescription }
            }
            rendering.remove(id)
        }
        #endif
    }

    #if os(macOS)
    private func apply(_ result: OfficeRenderer.Result, to doc: VLDocument) {
        doc.renderedPagePaths = result.paths
        doc.renderedPageTexts = result.texts
        let pages = doc.pages.sorted { $0.pageIndex < $1.pageIndex }
        if doc.kind == .pptx && pages.count == result.paths.count {
            for page in pages { page.renderedStart = page.pageIndex }
        } else {
            let starts = OriginalPages.startIndices(pageTexts: pages.map(\.extractedText),
                                                    renderedTexts: result.texts,
                                                    oneToOne: doc.kind == .pptx)
            for (page, start) in zip(pages, starts) { page.renderedStart = start }
        }
    }
    #endif
}

#if os(macOS)
/// Converts a PowerPoint or Word file to PDF and saves each page as an image.
enum OfficeRenderer {

    struct Result: Sendable {
        let paths: [String]
        let texts: [String]
    }

    enum RenderError: LocalizedError {
        case noConverter(DocumentKind)
        case notAllowed(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noConverter(let kind):
                "To show the original pages, install LibreOffice (brew install --cask libreoffice) or \(kind == .pptx ? "Keynote" : "Pages")."
            case .notAllowed(let app):
                "vLearning isn't allowed to use \(app). Turn it on in System Settings › Privacy & Security › Automation, then try again."
            case .failed(let message):
                "The pages couldn't be rendered. \(message)"
            }
        }
    }

    static func render(docId: UUID, kind: DocumentKind) throws -> Result {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("vl-render-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Work on a copy with a plain name, so nothing touches the stored original.
        let input = work.appendingPathComponent("document.\(kind.rawValue)")
        try fm.copyItem(at: DocumentStorage.originalURL(for: docId, kind: kind), to: input)

        let pdfURL = try convertToPDF(input, kind: kind, outDir: work)
        guard let pdf = PDFDocument(url: pdfURL), pdf.pageCount > 0 else {
            throw RenderError.failed("The converted file has no pages.")
        }

        let root = DocumentStorage.directory(for: docId)
        let dir = root.appendingPathComponent("rendered", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var paths: [String] = [], texts: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let relative = "rendered/\(i).jpg"
            if let data = PDFExtractor.renderPreview(page) {
                try data.write(to: root.appendingPathComponent(relative))
                paths.append(relative)
            } else {
                paths.append("")
            }
            texts.append(OriginalPages.words(page.string ?? "").joined(separator: " "))
        }
        return Result(paths: paths, texts: texts)
    }

    // MARK: - Converters

    private static func convertToPDF(_ input: URL, kind: DocumentKind, outDir: URL) throws -> URL {
        if let soffice = libreOffice {
            return try convertWithLibreOffice(soffice, input: input, outDir: outDir)
        }
        let app = kind == .pptx ? "Keynote" : "Pages"
        let bundleId = kind == .pptx ? "com.apple.iWork.Keynote" : "com.apple.iWork.Pages"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else {
            throw RenderError.noConverter(kind)
        }
        return try convertWithIWork(app, input: input, outDir: outDir)
    }

    private static var libreOffice: URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func convertWithLibreOffice(_ soffice: URL, input: URL, outDir: URL) throws -> URL {
        // Its own profile, so it works even while LibreOffice is open.
        let profile = EngineSupport.directory.appendingPathComponent("libreoffice-profile", isDirectory: true)
        let (status, output) = try run(soffice, [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--norestore", "--convert-to", "pdf", "--outdir", outDir.path, input.path,
        ], timeout: 300)
        let pdf = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
        guard status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw RenderError.failed("LibreOffice: \(output.suffix(300))")
        }
        return pdf
    }

    private static func convertWithIWork(_ app: String, input: URL, outDir: URL) throws -> URL {
        let pdf = outDir.appendingPathComponent("document.pdf")
        let script = """
        set wasRunning to application "\(app)" is running
        tell application "\(app)"
            set d to open (POSIX file "\(escape(input.path))")
            export d to (POSIX file "\(escape(pdf.path))") as PDF
            close d saving no
            if not wasRunning then quit
        end tell
        """
        // The first attempt can fail while the app is still launching.
        var lastError = ""
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 3) }
            let (status, output) = try run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script], timeout: 300)
            if status == 0, FileManager.default.fileExists(atPath: pdf.path) { return pdf }
            if output.contains("-1743") { throw RenderError.notAllowed(app) }
            lastError = output
        }
        throw RenderError.failed("\(app): \(lastError.suffix(300))")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs a command, killing it after `timeout`. Returns the exit status and its output.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (Int32, String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("vl-run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning && Date.now < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning {
            process.terminate()
            throw RenderError.failed("It took too long.")
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The app's support folder (also holds the engine log).
enum EngineSupport {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.darkopj.vlearning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
#endif
