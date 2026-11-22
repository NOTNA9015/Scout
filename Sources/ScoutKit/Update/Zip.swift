import Foundation
import Compression
import zlib

/// Just enough ZIP for IPAs: read an archive's file list, copy entries as they are (without
/// recompressing), and write new entries stored or deflated. Reads ZIP64 archives; writes plain
/// ZIP, which IPAs (well under 4 GB and 65,535 files) never outgrow. No encryption, no spanning.
struct ZipEntry: Equatable {
    var name: String
    var method: UInt16                 // 0 stored, 8 deflated
    var flags: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var size: UInt64
    var localHeaderOffset: UInt64
    var externalAttributes: UInt32
    var isDirectory: Bool { name.hasSuffix("/") }
    /// The Unix mode it was stored with, or a plain file's / folder's when the archive has none.
    var mode: UInt16 {
        let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
        return mode != 0 ? mode : (isDirectory ? 0o40755 : 0o100644)
    }
    var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}

enum ZipError: LocalizedError {
    case damaged(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .damaged(let what): return "The file is damaged (\(what))."
        case .unsupported(let what): return "This file uses something Scout can't read (\(what))."
        }
    }
}

/// A zip's checksum, fed in pieces.
struct CRC32 {
    private(set) var value: UInt = 0
    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.bindMemory(to: Bytef.self).baseAddress else { return }
        var at = 0
        while at < bytes.count {
            let length = min(bytes.count - at, Int(Int32.max))
            value = crc32(value, base + at, uInt(length))
            at += length
        }
    }
    var checksum: UInt32 { UInt32(truncatingIfNeeded: value) }
    static func of(_ data: Data) -> UInt32 { var crc = CRC32(); crc.update(data); return crc.checksum }
}

// MARK: Reading

final class ZipReader {
    let url: URL
    let entries: [ZipEntry]
    private let handle: FileHandle
    private let length: UInt64

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        length = try handle.seekToEnd()
        // The end record sits in the last 22 bytes plus up to 64 KB of comment.
        let tail = min(length, 65_557)
        let end = try Self.read(handle, at: length - tail, count: Int(tail))
        guard let at = Self.lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: end, minimumTail: 22) else { throw ZipError.damaged("no end of archive") }
        var count = UInt64(end.u16(at + 10)), directorySize = UInt64(end.u32(at + 12)), directoryOffset = UInt64(end.u32(at + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: a locator just before the end record points at the larger end record.
            guard at >= 20, end.u32(at - 20) == 0x0706_4B50 else { throw ZipError.damaged("no ZIP64 locator") }
            let record = try Self.read(handle, at: end.u64(at - 20 + 8), count: 56)
            guard record.u32(0) == 0x0606_4B50 else { throw ZipError.damaged("no ZIP64 end record") }
            count = record.u64(32); directorySize = record.u64(40); directoryOffset = record.u64(48)
        }
        guard directoryOffset + directorySize <= length, count < 1_000_000 else { throw ZipError.damaged("file list out of range") }
        let directory = try Self.read(handle, at: directoryOffset, count: Int(directorySize))
        var list: [ZipEntry] = [], cursor = 0
        list.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, directory.u32(cursor) == 0x0201_4B50 else { throw ZipError.damaged("file list") }
            let nameLength = Int(directory.u16(cursor + 28)), extraLength = Int(directory.u16(cursor + 30)), commentLength = Int(directory.u16(cursor + 32))
            guard cursor + 46 + nameLength + extraLength + commentLength <= directory.count else { throw ZipError.damaged("file list") }
            let nameBytes = directory.subdata(in: cursor + 46 ..< cursor + 46 + nameLength)
            var entry = ZipEntry(name: String(decoding: nameBytes, as: UTF8.self), method: directory.u16(cursor + 10), flags: directory.u16(cursor + 8),
                                 crc: directory.u32(cursor + 16), compressedSize: UInt64(directory.u32(cursor + 20)), size: UInt64(directory.u32(cursor + 24)),
                                 localHeaderOffset: UInt64(directory.u32(cursor + 42)), externalAttributes: directory.u32(cursor + 38))
            // ZIP64 sizes and offset, for whichever fields are full.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.u16(extra), size = Int(directory.u16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if entry.size == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { entry.size = directory.u64(field); field += 8 }
                    if entry.compressedSize == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { entry.compressedSize = directory.u64(field); field += 8 }
                    if entry.localHeaderOffset == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { entry.localHeaderOffset = directory.u64(field) }
                }
                extra += 4 + size
            }
            if entry.flags & 1 != 0 { throw ZipError.unsupported("encrypted files") }
            list.append(entry)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        entries = list
    }
    deinit { try? handle.close() }

    func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }

    /// Where an entry's (compressed) bytes start.
    func dataOffset(of entry: ZipEntry) throws -> UInt64 {
        let header = try Self.read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4B50 else { throw ZipError.damaged("\(entry.name) header") }
        let start = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        guard start + entry.compressedSize <= length else { throw ZipError.damaged("\(entry.name) is cut short") }
        return start
    }

    /// The stored bytes as they are, piece by piece.
    func readRaw(_ entry: ZipEntry, chunk: Int = 1 << 20, _ body: (Data) throws -> Void) throws {
        var offset = try dataOffset(of: entry), left = entry.compressedSize
        while left > 0 {
            let piece = try Self.read(handle, at: offset, count: Int(min(UInt64(chunk), left)))
            try body(piece)
            offset += UInt64(piece.count); left -= UInt64(piece.count)
        }
    }

    /// The entry's contents, piece by piece, inflated and checked against its checksum.
    func read(_ entry: ZipEntry, _ body: (Data) throws -> Void) throws {
        var crc = CRC32(), total: UInt64 = 0
        func emit(_ data: Data) throws { crc.update(data); total += UInt64(data.count); try body(data) }
        switch entry.method {
        case 0: try readRaw(entry) { try emit($0) }
        case 8:
            // InputFilter pulls compressed bytes as it needs them.
            var offset = try dataOffset(of: entry), left = entry.compressedSize
            let filter = try InputFilter(.decompress, using: .zlib, bufferCapacity: 1 << 20) { [handle] wanted -> Data? in
                guard left > 0 else { return nil }
                let piece = try Self.read(handle, at: offset, count: Int(min(UInt64(wanted), left)))
                offset += UInt64(piece.count); left -= UInt64(piece.count)
                return piece
            }
            while let piece = try filter.readData(ofLength: 1 << 20), !piece.isEmpty { try emit(piece) }
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard total == entry.size, crc.checksum == entry.crc else { throw ZipError.damaged("\(entry.name) checksum") }
    }

    /// Up to `count` bytes from the start of an entry, without inflating the rest (a binary's header).
    func prefix(of entry: ZipEntry, count: Int) throws -> Data {
        switch entry.method {
        case 0:
            let start = try dataOffset(of: entry)
            return try Self.read(handle, at: start, count: Int(min(UInt64(count), entry.compressedSize)))
        case 8:
            var offset = try dataOffset(of: entry), left = entry.compressedSize
            let filter = try InputFilter(.decompress, using: .zlib, bufferCapacity: 1 << 16) { [handle] wanted -> Data? in
                guard left > 0 else { return nil }
                let piece = try Self.read(handle, at: offset, count: Int(min(UInt64(wanted), left)))
                offset += UInt64(piece.count); left -= UInt64(piece.count)
                return piece
            }
            var data = Data()
            while data.count < count, let piece = try filter.readData(ofLength: count - data.count), !piece.isEmpty { data.append(piece) }
            return data
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    /// A small entry in one piece (Info.plist and the like).
    func data(of entry: ZipEntry, limit: UInt64 = 64 << 20) throws -> Data {
        guard entry.size <= limit else { throw ZipError.unsupported("\(entry.name) is too large to read at once") }
        var data = Data(capacity: Int(entry.size))
        try read(entry) { data.append($0) }
        return data
    }

    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipError.damaged("cut short") }
        return data
    }
    private static func lastIndex(of signature: [UInt8], in data: Data, minimumTail: Int) -> Int? {
        guard data.count >= minimumTail else { return nil }
        var at = data.count - minimumTail
        while at >= 0 {
            if data[data.startIndex + at] == signature[0], data[data.startIndex + at + 1] == signature[1],
               data[data.startIndex + at + 2] == signature[2], data[data.startIndex + at + 3] == signature[3] { return at }
            at -= 1
        }
        return nil
    }
}

// MARK: Writing

final class ZipWriter {
    private let handle: FileHandle
    private var directory = Data()
    private var count = 0
    private var offset: UInt64 = 0
    private let time: UInt16, date: UInt16

    init(url: URL, date when: Date = Date()) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: when)
        time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        date = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }
    deinit { try? handle.close() }

    /// Copies an entry from another archive without inflating it.
    func copy(_ entry: ZipEntry, from reader: ZipReader, as name: String? = nil) throws {
        let start = try beginEntry(name: name ?? entry.name, method: entry.method, crc: entry.crc,
                                   compressedSize: entry.compressedSize, size: entry.size, mode: entry.mode)
        try reader.readRaw(entry) { try write($0) }
        try endEntry(start: start)
    }

    /// A whole entry from memory, deflated unless it is tiny.
    func add(_ name: String, data: Data, mode: UInt16 = 0o100644) throws {
        try add(name, mode: mode, deflate: data.count > 64) { emit in try emit(data) }
    }

    /// An entry written piece by piece: `produce` hands its pieces to the closure it is given.
    func add(_ name: String, mode: UInt16, deflate: Bool, produce: ((Data) throws -> Void) throws -> Void) throws {
        let start = try beginEntry(name: name, method: deflate ? 8 : 0, crc: 0, compressedSize: 0, size: 0, mode: mode)
        var crc = CRC32(), size: UInt64 = 0, written: UInt64 = 0
        if deflate {
            let filter = try OutputFilter(.compress, using: .zlib) { [unowned self] piece in
                if let piece { try write(piece); written += UInt64(piece.count) }
            }
            try produce { piece in crc.update(piece); size += UInt64(piece.count); try filter.write(piece) }
            try filter.finalize()
        } else {
            try produce { piece in crc.update(piece); size += UInt64(piece.count); try write(piece); written += UInt64(piece.count) }
        }
        try patchSizes(start: start, crc: crc.checksum, compressedSize: written, size: size)
        try endEntry(start: start)
    }

    /// A folder entry ("Payload/").
    func addDirectory(_ name: String) throws {
        let start = try beginEntry(name: name.hasSuffix("/") ? name : name + "/", method: 0, crc: 0, compressedSize: 0, size: 0, mode: 0o40755)
        try endEntry(start: start)
    }

    func finish() throws {
        guard count < 0xFFFF, offset < 0xFFFF_FFFF, UInt64(directory.count) < 0xFFFF_FFFF else { throw ZipError.unsupported("an archive this large") }
        let directoryOffset = offset
        try write(directory)
        var end = Data()
        end.put32(0x0605_4B50); end.put16(0); end.put16(0); end.put16(UInt16(count)); end.put16(UInt16(count))
        end.put32(UInt32(directory.count)); end.put32(UInt32(directoryOffset)); end.put16(0)
        try write(end)
        try handle.synchronize()
        try handle.close()
    }

    // An entry's local header now; its central record once its sizes are known.
    private var pending: (name: Data, method: UInt16, crc: UInt32, compressedSize: UInt64, size: UInt64, mode: UInt16)?
    private func beginEntry(name: String, method: UInt16, crc: UInt32, compressedSize: UInt64, size: UInt64, mode: UInt16) throws -> UInt64 {
        let nameData = Data(name.utf8)
        guard offset < 0xFFFF_FFFF, compressedSize < 0xFFFF_FFFF, size < 0xFFFF_FFFF else { throw ZipError.unsupported("an archive this large") }
        let start = offset
        var header = Data()
        header.put32(0x0403_4B50); header.put16(20); header.put16(0x0800); header.put16(method); header.put16(time); header.put16(date)
        header.put32(crc); header.put32(UInt32(compressedSize)); header.put32(UInt32(size)); header.put16(UInt16(nameData.count)); header.put16(0)
        header.append(nameData)
        try write(header)
        pending = (nameData, method, crc, compressedSize, size, mode)
        return start
    }
    private func patchSizes(start: UInt64, crc: UInt32, compressedSize: UInt64, size: UInt64) throws {
        guard compressedSize < 0xFFFF_FFFF, size < 0xFFFF_FFFF else { throw ZipError.unsupported("a file this large") }
        var fields = Data(); fields.put32(crc); fields.put32(UInt32(compressedSize)); fields.put32(UInt32(size))
        try handle.seek(toOffset: start + 14)
        try handle.write(contentsOf: fields)
        try handle.seek(toOffset: offset)
        pending?.crc = crc; pending?.compressedSize = compressedSize; pending?.size = size
    }
    private func endEntry(start: UInt64) throws {
        guard let entry = pending else { return }
        var record = Data()
        record.put32(0x0201_4B50); record.put16(0x031E); record.put16(20); record.put16(0x0800); record.put16(entry.method); record.put16(time); record.put16(date)
        record.put32(entry.crc); record.put32(UInt32(entry.compressedSize)); record.put32(UInt32(entry.size))
        record.put16(UInt16(entry.name.count)); record.put16(0); record.put16(0); record.put16(0); record.put16(0)
        record.put32(UInt32(entry.mode) << 16); record.put32(UInt32(start))
        record.append(entry.name)
        directory.append(record); count += 1; pending = nil
    }
    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

// MARK: Little-endian fields

extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
    mutating func put16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(value & 0xFFFF)); put16(UInt16(value >> 16)) }
    mutating func setU32(_ value: UInt32, at: Int) {
        for byte in 0..<4 { self[startIndex + at + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF) }
    }
}
