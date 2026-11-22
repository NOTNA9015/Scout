import Foundation

/// Adds a library to an app's 64-bit Mach-O binary, the way cyan and Chroma's patcher do: one more
/// LC_LOAD_WEAK_DYLIB in the spare room after the load commands. Only the header changes; the
/// signature is stale afterwards and the signer replaces it.
enum MachOBinary {
    static let magic64: UInt32 = 0xFEED_FACF
    static let loadDylib: UInt32 = 0x0C, loadWeakDylib: UInt32 = 0x8000_0018, reexportDylib: UInt32 = 0x8000_001F
    static let lazyLoadDylib: UInt32 = 0x20, loadUpwardDylib: UInt32 = 0x8000_0023
    static let segment64: UInt32 = 0x19, encryptionInfo64: UInt32 = 0x2C

    enum Failure: LocalizedError {
        case notMachO, fat, encrypted, noRoom
        var errorDescription: String? {
            switch self {
            case .notMachO: return "The app's binary isn't a 64-bit iPhone binary."
            case .fat: return "The app's binary holds several architectures."
            case .encrypted: return "This IPA is encrypted. Use a decrypted Spotify IPA."
            case .noRoom: return "There's no room in the app's binary to add Scout."
            }
        }
    }

    /// How many leading bytes `addWeakDylib` needs to see: the header and load commands, plus room
    /// for one more. Valid once `prefix` holds at least the 32-byte header.
    static func headerLength(_ prefix: Data, adding path: String) throws -> Int {
        guard prefix.count >= 32 else { return 32 }
        try check(prefix)
        return 32 + Int(prefix.u32(20)) + command(for: path).count
    }

    struct Info { var dylibs: [String]; var encrypted: Bool; var firstSection: Int }
    static func info(_ header: Data) throws -> Info {
        try check(header)
        let count = Int(header.u32(16))
        var info = Info(dylibs: [], encrypted: false, firstSection: .max), at = 32
        for _ in 0..<count {
            guard at + 8 <= header.count else { throw Failure.notMachO }
            let cmd = header.u32(at), size = Int(header.u32(at + 4))
            guard size >= 8, at + size <= header.count else { throw Failure.notMachO }
            switch cmd {
            case loadDylib, loadWeakDylib, reexportDylib, lazyLoadDylib, loadUpwardDylib:
                let nameAt = at + Int(header.u32(at + 8))
                var end = nameAt
                while end < at + size, header[header.startIndex + end] != 0 { end += 1 }
                info.dylibs.append(String(decoding: header.subdata(in: header.startIndex + nameAt ..< header.startIndex + end), as: UTF8.self))
            case encryptionInfo64:
                if header.u32(at + 16) != 0 { info.encrypted = true }
            case segment64:
                let sections = Int(header.u32(at + 64))
                for index in 0..<sections {
                    let offset = Int(header.u32(at + 72 + index * 80 + 48))
                    if offset > 0 { info.firstSection = min(info.firstSection, offset) }
                }
            default: break
            }
            at += size
        }
        return info
    }

    /// Adds a weak load of `path` to the header in place. False when the binary already loads it.
    @discardableResult
    static func addWeakDylib(_ path: String, to header: inout Data) throws -> Bool {
        let info = try info(header)
        if info.encrypted { throw Failure.encrypted }
        if info.dylibs.contains(path) { return false }
        let command = command(for: path)
        let end = 32 + Int(header.u32(20))
        guard end + command.count <= min(info.firstSection, header.count),
              header[header.startIndex + end ..< header.startIndex + end + command.count].allSatisfy({ $0 == 0 }) else { throw Failure.noRoom }
        header.replaceSubrange(header.startIndex + end ..< header.startIndex + end + command.count, with: command)
        header.setU32(header.u32(16) + 1, at: 16)
        header.setU32(header.u32(20) + UInt32(command.count), at: 20)
        return true
    }

    /// LC_LOAD_WEAK_DYLIB: name after the 24-byte dylib command, padded to 8 bytes.
    static func command(for path: String) -> Data {
        let name = Data(path.utf8)
        let size = (24 + name.count + 1 + 7) & ~7
        var command = Data()
        command.put32(loadWeakDylib); command.put32(UInt32(size)); command.put32(24)
        command.put32(2); command.put32(0x1_0000); command.put32(0x1_0000)   // timestamp, current and compatibility version 1.0
        command.append(name)
        command.append(Data(count: size - command.count))
        return command
    }

    private static func check(_ header: Data) throws {
        guard header.count >= 32 else { throw Failure.notMachO }
        let magic = header.u32(0)
        if magic == 0xBEBA_FECA || magic == 0xBFBA_FECA { throw Failure.fat }
        guard magic == magic64 else { throw Failure.notMachO }
    }
}
