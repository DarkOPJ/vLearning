import Foundation

/// Minimal read-only ZIP reader — no external packages.
/// Handles stored (method 0) and DEFLATE-compressed (method 8) entries.
struct ZIPReader: Sendable {

    private struct Entry: Sendable {
        let dataOffset: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16
    }

    private let data: Data
    private let table: [String: Entry]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        table = try Self.parseEntries(from: data)
    }

    /// All file paths stored in the archive.
    var paths: [String] { Array(table.keys) }

    /// Returns decompressed data for the entry at `path`, or nil if not found.
    func extract(path: String) -> Data? {
        guard let e = table[path],
              e.dataOffset + e.compressedSize <= data.count
        else { return nil }
        let raw = data[e.dataOffset ..< e.dataOffset + e.compressedSize]
        switch e.method {
        case 0:  return Data(raw)
        case 8:  return inflateRaw(Data(raw), expected: e.uncompressedSize)
        default: return nil
        }
    }

    // MARK: - DEFLATE

    private func inflateRaw(_ compressed: Data, expected: Int) -> Data? {
        // Foundation's `.zlib` algorithm is raw DEFLATE (RFC 1951) with no zlib
        // header, which is exactly what ZIP entries store.
        guard let out = try? (compressed as NSData).decompressed(using: .zlib),
              !out.isEmpty
        else { return nil }
        let outData = out as Data
        return outData.count > expected ? Data(outData.prefix(expected)) : outData
    }

    // MARK: - Central Directory Parser

    private static func parseEntries(from data: Data) throws -> [String: Entry] {
        guard let eocdOff = findEOCD(in: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let cdOffset = Int(data.leUInt32(at: eocdOff + 16))
        let cdSize   = Int(data.leUInt32(at: eocdOff + 12))

        var table: [String: Entry] = [:]
        var pos = cdOffset

        while pos + 46 <= data.count, pos < cdOffset + cdSize {
            guard data.leUInt32(at: pos) == 0x02014B50 else { break }

            let method           = data.leUInt16(at: pos + 10)
            let compressedSize   = Int(data.leUInt32(at: pos + 20))
            let uncompressedSize = Int(data.leUInt32(at: pos + 24))
            let nameLen          = Int(data.leUInt16(at: pos + 28))
            let extraLen         = Int(data.leUInt16(at: pos + 30))
            let commentLen       = Int(data.leUInt16(at: pos + 32))
            let localOff         = Int(data.leUInt32(at: pos + 42))

            guard pos + 46 + nameLen <= data.count else { break }
            let nameBytes = data[(pos + 46) ..< (pos + 46 + nameLen)]
            let name = String(data: nameBytes, encoding: .utf8)
                    ?? String(data: nameBytes, encoding: .isoLatin1)
                    ?? ""

            // Local file header: 30 bytes fixed + name + extra → then data
            let localNameLen  = Int(data.leUInt16(at: localOff + 26))
            let localExtraLen = Int(data.leUInt16(at: localOff + 28))
            let dataOffset    = localOff + 30 + localNameLen + localExtraLen

            table[name] = Entry(dataOffset: dataOffset,
                                compressedSize: compressedSize,
                                uncompressedSize: uncompressedSize,
                                method: method)

            pos += 46 + nameLen + extraLen + commentLen
        }

        return table
    }

    // Scan backwards for the End-of-Central-Directory signature.
    private static func findEOCD(in data: Data) -> Int? {
        let sig: UInt32 = 0x06054B50
        let start = max(0, data.count - 66000)
        for i in stride(from: data.count - 22, through: start, by: -1) {
            if data.leUInt32(at: i) == sig { return i }
        }
        return nil
    }
}

// MARK: - Little-endian helpers

private extension Data {
    func leUInt16(at i: Int) -> UInt16 {
        guard i + 2 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt16.self) }
    }
    func leUInt32(at i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) }
    }
}
