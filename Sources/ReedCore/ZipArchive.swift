import Compression
import Foundation

/// Reads the files in a zip archive, as EPUBs are. Only what EPUBs use is supported:
/// stored and deflated entries, without encryption or ZIP64.
struct ZipArchive: Sendable {
    struct Entry: Sendable {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    enum Failure: Error { case notZip, unsupported, damaged, tooLarge }

    /// No single file in a book needs more.
    static let maximumEntrySize = 64 * 1024 * 1024

    private let data: Data
    /// Entries by path, as the archive names them.
    let entries: [String: Entry]

    /// Only the end of the archive and its directory are read, so a mapped file stays mostly on disk.
    init(_ data: Data) throws {
        self.data = data
        let start = data.startIndex
        // The end of central directory record is at least 22 bytes, followed by a comment of up to 64 KiB.
        guard data.count >= 22 else { throw Failure.notZip }
        let tailStart = max(0, data.count - 22 - 65535)
        let tail = [UInt8](data[(start + tailStart)...])
        var found: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) where Self.uint32(tail, offset) == 0x0605_4b50 {
            found = offset
            break
        }
        guard let found else { throw Failure.notZip }
        let count = Int(Self.uint16(tail, found + 10))
        guard Self.uint32(tail, found + 16) != 0xffff_ffff else { throw Failure.unsupported }
        let directoryStart = Int(Self.uint32(tail, found + 16)), directorySize = Int(Self.uint32(tail, found + 12))
        guard directoryStart + directorySize <= tailStart + found else { throw Failure.damaged }
        let directory = [UInt8](data[(start + directoryStart)..<(start + directoryStart + directorySize)])
        var offset = 0
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= directory.count, Self.uint32(directory, offset) == 0x0201_4b50 else { throw Failure.damaged }
            let flags = Self.uint16(directory, offset + 8)
            let nameLength = Int(Self.uint16(directory, offset + 28))
            let extraLength = Int(Self.uint16(directory, offset + 30))
            let commentLength = Int(Self.uint16(directory, offset + 32))
            guard offset + 46 + nameLength <= directory.count else { throw Failure.damaged }
            let name = String(decoding: directory[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if flags & 1 == 0 {
                entries[name] = Entry(method: Self.uint16(directory, offset + 10), compressedSize: Int(Self.uint32(directory, offset + 20)),
                                      size: Int(Self.uint32(directory, offset + 24)), headerOffset: Int(Self.uint32(directory, offset + 42)))
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The contents of the file at `path`, or nil if there's no such file.
    func file(_ path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.size <= Self.maximumEntrySize else { throw Failure.tooLarge }
        let header = entry.headerOffset
        guard header + 30 <= data.count else { throw Failure.damaged }
        let start = data.startIndex
        let local = [UInt8](data[(start + header)..<(start + header + 30)])
        guard Self.uint32(local, 0) == 0x0403_4b50 else { throw Failure.damaged }
        let body = header + 30 + Int(Self.uint16(local, 26)) + Int(Self.uint16(local, 28))
        guard body + entry.compressedSize <= data.count else { throw Failure.damaged }
        let compressed = data[(start + body)..<(start + body + entry.compressedSize)]
        switch entry.method {
        case 0: return Data(compressed)
        case 8:
            if entry.size == 0 { return Data() }
            guard entry.compressedSize > 0 else { throw Failure.damaged }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    // Apple's zlib format is raw deflate, as zip stores it.
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              source.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged }
            return output
        default: throw Failure.unsupported
        }
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
