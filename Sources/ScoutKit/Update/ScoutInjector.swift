import Foundation

/// Puts Scout into a Spotify IPA, the way scripts/package.py does on a Mac: ScoutKit.framework in
/// the app's Frameworks, a weak load of it in the app's binary, and Scout's keys in its Info.plist.
/// Every other file is copied byte for byte, so whatever else the IPA carries (Chroma) is kept.
/// The input is never changed. Chroma's updater then patches the result and keeps Scout in it.
public enum ScoutInjector {
    static let loadPath = "@rpath/ScoutKit.framework/ScoutKit"
    static let frameworkFolder = "Frameworks/ScoutKit.framework"

    /// What an IPA (or an installed app) holds, as far as Scout cares.
    public struct App: Equatable {
        /// "Payload/Spotify.app/"
        public var directory: String
        public var executable: String
        public var bundleID: String?
        /// Spotify's own version.
        public var version: String?
        /// The ScoutKit.framework inside, if any ("unknown" when it has no version).
        public var scoutVersion: String?
        /// The app's binary loads Scout.
        public var loadsScout: Bool
        public var hasChroma: Bool
        public var encrypted: Bool
        public var isSpotify: Bool { executable == "Spotify" }
    }

    public enum Failure: LocalizedError {
        case notAnApp, noFramework
        public var errorDescription: String? {
            switch self {
            case .notAnApp: return "This file isn't an app IPA."
            case .noFramework: return "Scout's framework is missing."
            }
        }
    }

    // MARK: Looking

    public static func inspect(ipa: URL) throws -> App { try inspect(ZipReader(url: ipa)) }

    static func inspect(_ reader: ZipReader) throws -> App {
        let infos = reader.entries.filter { $0.name.hasPrefix("Payload/") && $0.name.hasSuffix(".app/Info.plist") && $0.name.split(separator: "/").count == 3 }
        guard infos.count == 1, let infoEntry = infos.first else { throw Failure.notAnApp }
        let directory = String(infoEntry.name.dropLast("Info.plist".count))
        guard let info = try PropertyListSerialization.propertyList(from: reader.data(of: infoEntry), format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              let binary = reader.entry(named: directory + executable) else { throw Failure.notAnApp }
        let header = try reader.prefix(of: binary, count: 256 << 10)
        let machO = try? MachOBinary.info(header)
        var scoutVersion: String?
        if let plist = reader.entry(named: directory + frameworkFolder + "/Info.plist") {
            scoutVersion = (try? PropertyListSerialization.propertyList(from: reader.data(of: plist), format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "unknown"
        } else if reader.entry(named: directory + frameworkFolder + "/ScoutKit") != nil { scoutVersion = "unknown" }
        return App(directory: directory, executable: executable, bundleID: info["CFBundleIdentifier"] as? String,
                   version: info["CFBundleShortVersionString"] as? String, scoutVersion: scoutVersion,
                   loadsScout: machO?.dylibs.contains(loadPath) ?? false,
                   hasChroma: reader.entry(named: directory + "Frameworks/spotifyglass.dylib") != nil,
                   encrypted: machO?.encrypted ?? false)
    }

    /// The version of a ScoutKit.framework folder.
    public static func version(ofFramework url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Whether `app` should get `version` of Scout: it has no Scout, doesn't load it, or has an older one.
    public static func needsScout(_ app: App, version: String) -> Bool {
        guard app.loadsScout, let inside = app.scoutVersion, inside != "unknown" else { return true }
        return ScoutVersion.isNewer(version, than: inside)
    }

    // MARK: Writing

    /// Writes `output`: `ipa` with `framework` in place of any Scout it had.
    @discardableResult
    public static func inject(ipa: URL, framework: URL, to output: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> App {
        guard let scoutVersion = version(ofFramework: framework) else { throw Failure.noFramework }
        let reader = try ZipReader(url: ipa)
        let app = try inspect(reader)
        if app.encrypted { throw MachOBinary.Failure.encrypted }
        let frameworkFiles = try files(in: framework)
        let total = Double(reader.entries.reduce(0) { $0 + $1.compressedSize } + frameworkFiles.reduce(0) { $0 + $1.size })
        var done: UInt64 = 0
        try write(output) { writer in
            let oldScout = app.directory + frameworkFolder
            for entry in reader.entries {
                defer { done += entry.compressedSize; progress(Double(done) / max(total, 1)) }
                if entry.name == oldScout + "/" || entry.name.hasPrefix(oldScout + "/") { continue }
                if entry.name == app.directory + "Info.plist" {
                    try writer.add(entry.name, data: merged(plist: reader.data(of: entry), scoutVersion: scoutVersion), mode: entry.mode)
                } else if entry.name == app.directory + app.executable {
                    try writer.add(entry.name, mode: entry.mode, deflate: true) { emit in
                        try addLoad(from: { sink in try reader.read(entry, sink) }, emit: emit)
                    }
                } else {
                    try writer.copy(entry, from: reader)
                }
            }
            try add(frameworkFiles, under: oldScout, to: writer) { done += $0; progress(Double(done) / max(total, 1)) }
        }
        return try inspect(ipa: output)
    }

    /// Packs an installed app (this one, inside Spotify) into an IPA at `output`, with `framework`
    /// in place of the Scout it runs now. Chroma's updater can install it like any Spotify IPA.
    @discardableResult
    public static func pack(app bundle: URL, framework: URL, to output: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> App {
        guard let scoutVersion = version(ofFramework: framework) else { throw Failure.noFramework }
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String else { throw Failure.notAnApp }
        let directory = "Payload/" + bundle.lastPathComponent + "/"
        let oldScout = frameworkFolder
        let appFiles = try files(in: bundle).filter { $0.path != oldScout && !$0.path.hasPrefix(oldScout + "/") }
        let frameworkFiles = try files(in: framework)
        let total = Double(appFiles.reduce(0) { $0 + $1.size } + frameworkFiles.reduce(0) { $0 + $1.size })
        var done: UInt64 = 0
        try write(output) { writer in
            for file in appFiles {
                defer { done += file.size; progress(Double(done) / max(total, 1)) }
                let name = directory + file.path
                if file.isLink {
                    try writer.add(name, data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.url.path).utf8), mode: 0o120755)
                } else if file.path == "Info.plist" {
                    try writer.add(name, data: merged(plist: Data(contentsOf: file.url), scoutVersion: scoutVersion), mode: file.mode)
                } else if file.path == executable {
                    try writer.add(name, mode: file.mode, deflate: true) { emit in try addLoad(from: { sink in try stream(file.url, sink) }, emit: emit) }
                } else {
                    try writer.add(name, mode: file.mode, deflate: file.size > 64) { emit in try stream(file.url, emit) }
                }
            }
            try add(frameworkFiles, under: directory + oldScout, to: writer) { done += $0; progress(Double(done) / max(total, 1)) }
        }
        return try inspect(ipa: output)
    }

    /// Scout's keys in an app's Info.plist, keeping everything else as it is.
    static func merged(plist data: Data, scoutVersion: String) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { throw Failure.notAnApp }
        info["ScoutVersion"] = scoutVersion
        info["UIFileSharingEnabled"] = true
        info["LSSupportsOpeningDocumentsInPlace"] = true
        if info["NSSpeechRecognitionUsageDescription"] == nil {
            info["NSSpeechRecognitionUsageDescription"] = "Scout writes timed lyrics from your audio on this iPhone."
        }
        return try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
    }

    /// Streams a binary through, adding Scout's load command to its header on the way.
    static func addLoad(from source: ((Data) throws -> Void) throws -> Void, emit: (Data) throws -> Void) throws {
        var head = Data(), patched = false
        try withoutActuallyEscaping(emit) { emit in
            try source { piece in
                if patched { try emit(piece); return }
                head.append(piece)
                guard head.count >= (try MachOBinary.headerLength(head, adding: loadPath)) else { return }
                try MachOBinary.addWeakDylib(loadPath, to: &head)
                try emit(head); head = Data(); patched = true
            }
        }
        if !patched { throw MachOBinary.Failure.notMachO }
    }

    // MARK: Files

    struct File { var url: URL; var path: String; var size: UInt64; var mode: UInt16; var isLink: Bool }

    /// Every file under `root` (not folders), skipping hidden ones as Chroma's patcher does.
    static func files(in root: URL) throws -> [File] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { throw Failure.notAnApp }
        var list: [File] = []
        while let path = walker.nextObject() as? String {
            let url = root.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)   // the link itself, not its target
            let type = attributes[.type] as? FileAttributeType
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { if type == .typeDirectory { walker.skipDescendants() }; continue }
            if type == .typeDirectory { continue }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            list.append(File(url: url, path: path, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                             mode: 0o100000 | (permissions & 0o777), isLink: type == .typeSymbolicLink))
        }
        return list.sorted { $0.path < $1.path }
    }

    private static func add(_ files: [File], under folder: String, to writer: ZipWriter, advanced: (UInt64) -> Void) throws {
        for file in files {
            try writer.add(folder + "/" + file.path, mode: file.mode, deflate: file.size > 64) { emit in try stream(file.url, emit) }
            advanced(file.size)
        }
    }

    static func stream(_ url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { try body(piece) }
    }

    /// Writes beside `output` first, so a failure never leaves half an IPA under its name.
    private static func write(_ output: URL, _ body: (ZipWriter) throws -> Void) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.deletingLastPathComponent().appendingPathComponent("." + output.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: partial)
        do {
            let writer = try ZipWriter(url: partial)
            try body(writer)
            try writer.finish()
            if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: partial) }
            else { try FileManager.default.moveItem(at: partial, to: output) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}

/// "1.2.10" style versions, compared number by number ("v" prefix allowed).
public enum ScoutVersion {
    static func parts(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
