import Foundation
import CoreGraphics
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

            let body = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            pages.append(ExtractedPage(
                index: i,
                bodyText: body,
                imageData: page.pageRef.map(embeddedImages(in:)) ?? [],
                previewData: renderPreview(page),
                isLikelyScanned: body.count < ExtractedPage.scannedThreshold
            ))
        }

        return pages
    }

    // MARK: - Page preview

    private static let previewWidth: CGFloat = 1500

    /// Renders the whole page; used as the "original" view and, for scanned pages, as the OCR source.
    static func renderPreview(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rotated = page.rotation % 180 != 0
        let aspect = rotated ? bounds.width / bounds.height : bounds.height / bounds.width
        let size = CGSize(width: previewWidth, height: previewWidth * aspect)

        let thumb = page.thumbnail(of: size, for: .cropBox)
        #if os(iOS)
        guard let cg = thumb.cgImage else { return nil }
        #else
        guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        return ImageCoding.jpeg(from: cg)
    }

    // MARK: - Embedded images

    /// Images smaller than this on their longest side are skipped (icons, rules, bullets).
    private static let minImageSide = 100

    /// Pulls image XObjects out of the page's resources, including ones nested in form XObjects.
    private static func embeddedImages(in page: CGPDFPage) -> [Data] {
        guard let pageDict = page.dictionary else { return [] }
        var results: [Data] = []
        var seen = Set<Int>()
        collectImages(fromResourcesOf: pageDict, into: &results, seen: &seen, depth: 0)
        return results
    }

    private static func collectImages(
        fromResourcesOf dict: CGPDFDictionaryRef,
        into results: inout [Data],
        seen: inout Set<Int>,
        depth: Int
    ) {
        guard depth < 4 else { return }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects
        else { return }

        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)

        for stream in streams {
            guard seen.insert(unsafeBitCast(stream, to: Int.self)).inserted,
                  let streamDict = CGPDFStreamGetDictionary(stream)
            else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype else { continue }

            switch String(cString: subtype) {
            case "Image":
                if let jpeg = decodeImage(stream, dict: streamDict) { results.append(jpeg) }
            case "Form":
                collectImages(fromResourcesOf: streamDict, into: &results, seen: &seen, depth: depth + 1)
            default:
                break
            }
        }
    }

    private static func decodeImage(_ stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) -> Data? {
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask), isMask != 0 { return nil }

        var width = 0, height = 0, bpc = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width),
              CGPDFDictionaryGetInteger(dict, "Height", &height),
              max(width, height) >= minImageSide
        else { return nil }

        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data

        switch format {
        case .jpegEncoded, .JPEG2000:
            // Re-encode so CMYK / JPEG 2000 sources end up as plain RGB JPEG.
            return ImageCoding.jpeg(from: data) ?? (format == .jpegEncoded ? data : nil)
        case .raw:
            guard CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc), bpc == 8,
                  let components = colorComponents(dict)
            else { return nil }
            let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = width * components
            guard data.count >= bytesPerRow * height,
                  let provider = CGDataProvider(data: cfData),
                  let image = CGImage(
                    width: width, height: height,
                    bitsPerComponent: 8, bitsPerPixel: 8 * components,
                    bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return ImageCoding.jpeg(from: image)
        @unknown default:
            return nil
        }
    }

    /// 1 for gray, 3 for RGB; nil for color spaces we don't decode (CMYK, indexed, …).
    private static func colorComponents(_ dict: CGPDFDictionaryRef) -> Int? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceRGB", "CalRGB": return 3
            case "DeviceGray", "CalGray": return 1
            default: return nil
            }
        }
        // [/ICCBased stream] — read N from the ICC stream's dictionary.
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let array else { return nil }
        var family: UnsafePointer<CChar>?
        var iccStream: CGPDFStreamRef?
        guard CGPDFArrayGetName(array, 0, &family), let family,
              String(cString: family) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &iccStream), let iccStream,
              let iccDict = CGPDFStreamGetDictionary(iccStream)
        else { return nil }
        var n = 0
        guard CGPDFDictionaryGetInteger(iccDict, "N", &n), n == 1 || n == 3 else { return nil }
        return n
    }
}
