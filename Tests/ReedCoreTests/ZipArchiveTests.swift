import Foundation
import Testing
@testable import ReedCore

private struct ZipEntry {
    var name: String
    var method: UInt16 = 0
    var body: [UInt8]
    var size: Int?
    var headerOffset: Int?
}

private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)] }
private func le32(_ value: Int) -> [UInt8] { le16(value & 0xffff) + le16(value >> 16 & 0xffff) }

/// A zip of `entries`, without CRCs, which the reader doesn't check.
private func zip(_ entries: [ZipEntry], directoryOffset: Int? = nil, directorySize: Int? = nil) -> Data {
    var bytes: [UInt8] = [], directory: [UInt8] = []
    for entry in entries {
        let name = Array(entry.name.utf8)
        let offset = bytes.count
        bytes += le32(0x0403_4b50) + le16(20) + le16(0) + le16(Int(entry.method)) + le32(0) + le32(0)
            + le32(entry.body.count) + le32(entry.size ?? entry.body.count) + le16(name.count) + le16(0) + name + entry.body
        directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(Int(entry.method)) + le32(0) + le32(0)
            + le32(entry.body.count) + le32(entry.size ?? entry.body.count) + le16(name.count) + le16(0) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(entry.headerOffset ?? offset) + name
    }
    let start = bytes.count
    bytes += directory
    bytes += le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
        + le32(directorySize ?? directory.count) + le32(directoryOffset ?? start) + le16(0)
    return Data(bytes)
}

/// "hello" as a single stored deflate block.
private let deflatedHello: [UInt8] = [0x01, 0x05, 0x00, 0xfa, 0xff] + Array("hello".utf8)

@Test func zipEntriesReadBackAndMissingPathsAreNil() throws {
    let archive = try ZipArchive(zip([ZipEntry(name: "a.txt", body: Array("stored".utf8)),
                                      ZipEntry(name: "b.txt", method: 8, body: deflatedHello, size: 5)]))
    #expect(try archive.file("a.txt") == Data("stored".utf8))
    #expect(try archive.file("b.txt") == Data("hello".utf8))
    #expect(try archive.file("c.txt") == nil)
}

@Test func zipDirectoriesPastTheEndAreRefused() {
    let entries = [ZipEntry(name: "a.txt", body: Array("stored".utf8))]
    #expect(throws: ZipArchive.Failure.damaged) { try ZipArchive(zip(entries, directoryOffset: 10_000)) }
    #expect(throws: ZipArchive.Failure.damaged) { try ZipArchive(zip(entries, directorySize: 10_000)) }
}

@Test func zipEntriesWhoseHeaderIsPastTheEndAreRefused() throws {
    let archive = try ZipArchive(zip([ZipEntry(name: "a.txt", body: Array("stored".utf8), headerOffset: 10_000)]))
    #expect(throws: ZipArchive.Failure.damaged) { try archive.file("a.txt") }
}

@Test func deflatedEntriesThatDontInflateToTheirSizeAreRefused() throws {
    let archive = try ZipArchive(zip([ZipEntry(name: "short", method: 8, body: deflatedHello, size: 10),
                                      ZipEntry(name: "garbage", method: 8, body: [0xff, 0xff, 0xff, 0xff], size: 5)]))
    #expect(throws: ZipArchive.Failure.damaged) { try archive.file("short") }
    #expect(throws: ZipArchive.Failure.damaged) { try archive.file("garbage") }
}

@Test func tooShortDataIsNotAZip() {
    #expect(throws: ZipArchive.Failure.notZip) { try ZipArchive(Data(count: 21)) }
    #expect(throws: ZipArchive.Failure.notZip) { try ZipArchive(Data()) }
}
