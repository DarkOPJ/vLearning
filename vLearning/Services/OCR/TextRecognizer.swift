import Foundation
import CoreGraphics
import ImageIO
import Vision

/// On-device OCR with Apple Vision. English, accurate mode, with language correction.
enum TextRecognizer {

    enum Failure: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "The image could not be read." }
    }

    /// Recognizes the text in an image file and returns it as lines in reading order.
    static func recognize(imageAt url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadableImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        try VNImageRequestHandler(cgImage: image).perform([request])

        let lines = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty
            else { return nil }
            return (obs.boundingBox, text)
        }
        return readingOrder(lines).map(\.text).joined(separator: "\n")
    }

    /// Top-to-bottom, then left-to-right for lines sitting on the same row.
    /// Vision boxes are normalized with the origin at the bottom-left.
    private static func readingOrder(_ lines: [(box: CGRect, text: String)]) -> [(box: CGRect, text: String)] {
        lines.sorted { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }
    }
}
