import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Platform-neutral image helpers built on ImageIO.
enum ImageCoding {

    /// Re-encodes any ImageIO-readable image (PNG, TIFF, JPEG 2000, EMF is not supported) as JPEG.
    /// Returns nil when the data can't be decoded or is smaller than `minSide` on both sides.
    static func jpeg(from data: Data, minSide: Int = 0) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return jpeg(from: image, minSide: minSide)
    }

    static func jpeg(from image: CGImage, minSide: Int = 0, quality: Double = 0.85) -> Data? {
        guard max(image.width, image.height) >= minSide else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Downsampled image for display, without decoding the full-size bitmap.
    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
