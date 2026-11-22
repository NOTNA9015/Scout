import XCTest
import ObjectiveC
@testable import ScoutKit

/// Synthetic IPAs, binaries and frameworks for the update tests.
enum UpdateFixtures {
    static let scoutLoad = "@rpath/ScoutKit.framework/ScoutKit"

    /// A thin arm64 Mach-O: a __TEXT segment whose first section starts `padding` bytes after the
    /// load commands, the given dylib loads, and `body` bytes after that.
    static func machO(dylibs: [String], filetype: UInt32 = 2, padding: Int = 4096, encrypted: Bool = false, body: Int = 200_000) -> Data {
        var commands = Data()
        for path in dylibs { commands.append(MachOBinary.command(for: path)) }
        if encrypted { var c = Data(); c.put32(0x2C); c.put32(24); c.put32(0x4000); c.put32(0x1000); c.put32(1); c.put32(0); commands.append(c) }
        let segmentSize = 72 + 80
        let sizeofcmds = segmentSize + commands.count
        let firstSection = 32 + sizeofcmds + padding
        var segment = Data(); segment.put32(0x19); segment.put32(UInt32(segmentSize)); segment.append(Data("__TEXT".utf8) + Data(count: 10))
        segment.append(Data(count: 32)); segment.put32(5); segment.put32(5); segment.put32(1); segment.put32(0)
        var section = Data(); section.append(Data("__text".utf8) + Data(count: 10)); section.append(Data("__TEXT".utf8) + Data(count: 10))
        section.append(Data(count: 16)); section.put32(UInt32(firstSection)); section.append(Data(count: 28))
        var header = Data(); header.put32(MachOBinary.magic64); header.put32(0x0100_000C); header.put32(0); header.put32(filetype)
        header.put32(UInt32(1 + dylibs.count + (encrypted ? 1 : 0))); header.put32(UInt32(sizeofcmds)); header.put32(0); header.put32(0)
        var binary = header + segment + section + commands
        binary.append(Data(count: firstSection - binary.count))
        binary.append(Data((0..<body).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 97) }))
        return binary
    }

    static func plist(_ values: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) }

    /// A Spotify IPA with Chroma's dylib beside it; `scout` adds a ScoutKit.framework of that version and build.
    @discardableResult
    static func spotifyIPA(at url: URL, scout: String? = nil, build: Int = 1, encrypted: Bool = false) throws -> [String: Data] {
        let app = "Payload/Spotify.app/"
        var files: [String: Data] = [
            app + "Info.plist": plist(["CFBundleExecutable": "Spotify", "CFBundleIdentifier": "com.spotify.client", "CFBundleShortVersionString": "9.1.98", "Kept": "yes"]),
            app + "Spotify": machO(dylibs: ["@rpath/SpotifyShared.framework/SpotifyShared", "@rpath/spotifyglass.dylib"] + (scout != nil ? [scoutLoad] : []), encrypted: encrypted),
            app + "Frameworks/spotifyglass.dylib": machO(dylibs: [], filetype: 6, body: 5_000),
            app + "PlugIns/Widget.appex/Widget": machO(dylibs: [], body: 3_000),
            app + "Assets.car": Data(repeating: 7, count: 40_000),
            app + "en.lproj/Localizable.strings": Data("\"a\" = \"b\";".utf8),
        ]
        if let scout {
            files[app + "Frameworks/ScoutKit.framework/Info.plist"] = plist(["CFBundleShortVersionString": scout, "CFBundleVersion": String(build), "CFBundleExecutable": "ScoutKit"])
            files[app + "Frameworks/ScoutKit.framework/ScoutKit"] = machO(dylibs: [], filetype: 6, body: 1_000)
            files[app + "Frameworks/ScoutKit.framework/Only in \(scout).txt"] = Data(scout.utf8)
        }
        let writer = try ZipWriter(url: url)
        for name in files.keys.sorted() {
            let executable = name.hasSuffix("/Spotify") || name.hasSuffix(".dylib") || name.hasSuffix("/Widget") || name.hasSuffix("/ScoutKit")
            try writer.add(name, data: files[name]!, mode: executable ? 0o100755 : 0o100644)
        }
        try writer.finish()
        return files
    }

    /// A ScoutKit.framework folder of `version` and `build`.
    static func framework(_ version: String, build: Int = 1, in folder: URL) throws -> URL {
        let framework = folder.appendingPathComponent("ScoutKit.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try plist(["CFBundleShortVersionString": version, "CFBundleVersion": String(build), "CFBundleExecutable": "ScoutKit"]).write(to: framework.appendingPathComponent("Info.plist"))
        let binary = framework.appendingPathComponent("ScoutKit")
        try machO(dylibs: [], filetype: 6, body: 2_000).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data(version.utf8).write(to: framework.appendingPathComponent("Version \(version).txt"))
        return framework
    }

    static func contents(of url: URL) throws -> [String: Data] {
        let reader = try ZipReader(url: url)
        var files: [String: Data] = [:]
        for entry in reader.entries where !entry.isDirectory { files[entry.name] = try reader.data(of: entry, limit: 1 << 30) }
        return files
    }
}

final class ZipAndMachOTests: XCTestCase {
    var work: URL!
    override func setUp() { work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func testZipWritesReadsAndCopiesEntries() throws {
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 % 251 ^ $0 / 4096) })
        let first = work.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: first)
        try writer.addDirectory("Payload")
        try writer.add("Payload/tiny.txt", data: Data("hi".utf8))
        try writer.add("Payload/big.bin", data: big, mode: 0o100755)
        try writer.finish()

        let reader = try ZipReader(url: first)
        XCTAssertEqual(reader.entries.map(\.name), ["Payload/", "Payload/tiny.txt", "Payload/big.bin"])
        let bigEntry = try XCTUnwrap(reader.entry(named: "Payload/big.bin"))
        XCTAssertEqual(bigEntry.method, 8, "large entries are deflated")
        XCTAssertLessThan(bigEntry.compressedSize, bigEntry.size)
        XCTAssertEqual(bigEntry.mode, 0o100755)
        XCTAssertEqual(try reader.data(of: bigEntry), big)
        XCTAssertEqual(try reader.prefix(of: bigEntry, count: 1000), big.prefix(1000))
        XCTAssertEqual(try reader.data(of: XCTUnwrap(reader.entry(named: "Payload/tiny.txt"))), Data("hi".utf8))

        // Copying moves the compressed bytes as they are.
        let second = work.appendingPathComponent("b.zip")
        let copier = try ZipWriter(url: second)
        try copier.copy(bigEntry, from: reader, as: "Payload/copy.bin")
        try copier.finish()
        let copy = try XCTUnwrap(ZipReader(url: second).entry(named: "Payload/copy.bin"))
        XCTAssertEqual(copy.crc, bigEntry.crc); XCTAssertEqual(copy.compressedSize, bigEntry.compressedSize)
        XCTAssertEqual(try ZipReader(url: second).data(of: copy), big)
    }

    func testADamagedEntryIsCaught() throws {
        let url = work.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: url)
        try writer.add("file", data: Data(repeating: 1, count: 10), mode: 0o100644)   // stored: tiny
        try writer.finish()
        var bytes = try Data(contentsOf: url)
        bytes[30 + 4] ^= 0xFF   // inside the file's data, after its 30-byte header and 4-byte name
        try bytes.write(to: url)
        let reader = try ZipReader(url: url)
        XCTAssertThrowsError(try reader.data(of: reader.entries[0]))
    }

    func testScoutsLoadIsAddedOnceAndNothingElseMoves() throws {
        let original = UpdateFixtures.machO(dylibs: ["@rpath/spotifyglass.dylib"])
        var binary = original
        XCTAssertTrue(try MachOBinary.addWeakDylib(UpdateFixtures.scoutLoad, to: &binary))
        XCTAssertEqual(try MachOBinary.info(binary).dylibs, ["@rpath/spotifyglass.dylib", UpdateFixtures.scoutLoad])
        XCTAssertEqual(binary.count, original.count, "the command goes into the spare room")
        XCTAssertEqual(binary.u32(16), original.u32(16) + 1)
        let firstSection = try MachOBinary.info(original).firstSection
        XCTAssertEqual(binary[firstSection...], original[firstSection...])
        XCTAssertFalse(try MachOBinary.addWeakDylib(UpdateFixtures.scoutLoad, to: &binary), "already there")
        XCTAssertEqual(try MachOBinary.info(binary).dylibs.filter { $0 == UpdateFixtures.scoutLoad }.count, 1)
    }

    func testABinaryWithoutRoomOrEncryptedIsRefused() {
        var tight = UpdateFixtures.machO(dylibs: [], padding: 16)
        XCTAssertThrowsError(try MachOBinary.addWeakDylib(UpdateFixtures.scoutLoad, to: &tight)) { XCTAssertEqual($0 as? MachOBinary.Failure, .noRoom) }
        var encrypted = UpdateFixtures.machO(dylibs: [], encrypted: true)
        XCTAssertThrowsError(try MachOBinary.addWeakDylib(UpdateFixtures.scoutLoad, to: &encrypted)) { XCTAssertEqual($0 as? MachOBinary.Failure, .encrypted) }
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE]) + Data(count: 60)
        XCTAssertThrowsError(try MachOBinary.addWeakDylib(UpdateFixtures.scoutLoad, to: &fat)) { XCTAssertEqual($0 as? MachOBinary.Failure, .fat) }
    }

    func testVersionsAreOrderedByBuildWhateverTheirNames() {
        XCTAssertTrue(ScoutVersion("0.1.2", build: 4).isNewer(than: ScoutVersion("1.1.1", build: 3)), "Scout's own numbers start over at 0.1")
        XCTAssertTrue(ScoutVersion("0.1.3", build: 6).isNewer(than: ScoutVersion("0.2", build: 5)))
        XCTAssertFalse(ScoutVersion("0.1.2", build: 4).isNewer(than: ScoutVersion("0.1.2", build: 4)))
        XCTAssertEqual(ScoutVersion(info: ["CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "4"]), ScoutVersion("0.1.2", build: 4))
        XCTAssertEqual(ScoutVersion(info: ["CFBundleShortVersionString": "0.1"])?.build, 0, "no build number counts as the oldest")
    }
}

final class ScoutInjectorTests: XCTestCase {
    var work: URL!
    override func setUp() { work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func testScoutIsAddedToACleanSpotifyIPAAndEverythingElseIsKept() throws {
        let clean = work.appendingPathComponent("Spotify.ipa"), output = work.appendingPathComponent("out.ipa")
        let original = try UpdateFixtures.spotifyIPA(at: clean)
        let before = try ScoutInjector.inspect(ipa: clean)
        XCTAssertNil(before.scoutVersion); XCTAssertFalse(before.loadsScout); XCTAssertTrue(before.hasChroma)
        XCTAssertTrue(ScoutInjector.needsScout(before, version: ScoutVersion("1.0.0", build: 1)))

        let app = try ScoutInjector.inject(ipa: clean, framework: UpdateFixtures.framework("1.0.0", in: work), to: output)
        XCTAssertEqual(app.scoutVersion, "1.0.0"); XCTAssertEqual(app.scoutBuild, 1); XCTAssertTrue(app.loadsScout); XCTAssertTrue(app.hasChroma)
        XCTAssertFalse(ScoutInjector.needsScout(app, version: ScoutVersion("1.0.0", build: 1)))
        XCTAssertEqual(try Data(contentsOf: clean), try Data(contentsOf: clean), "input untouched")

        let files = try UpdateFixtures.contents(of: output)
        let dir = "Payload/Spotify.app/"
        for (name, data) in original where name != dir + "Info.plist" && name != dir + "Spotify" { XCTAssertEqual(files[name], data, name) }
        XCTAssertNotNil(files[dir + "Frameworks/ScoutKit.framework/ScoutKit"])
        XCTAssertNotNil(files[dir + "Frameworks/ScoutKit.framework/Version 1.0.0.txt"])
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: files[dir + "Info.plist"]!, format: nil) as? [String: Any])
        XCTAssertEqual(info["ScoutVersion"] as? String, "1.0.0"); XCTAssertEqual(info["Kept"] as? String, "yes"); XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        let binary = try XCTUnwrap(files[dir + "Spotify"]), was = try XCTUnwrap(original[dir + "Spotify"])
        XCTAssertEqual(binary.count, was.count)
        XCTAssertEqual(try MachOBinary.info(binary).dylibs.last, UpdateFixtures.scoutLoad)
        let modes = Dictionary(uniqueKeysWithValues: try ZipReader(url: output).entries.map { ($0.name, $0.mode) })
        XCTAssertEqual(modes[dir + "Spotify"], 0o100755); XCTAssertEqual(modes[dir + "Frameworks/ScoutKit.framework/ScoutKit"], 0o100755)
    }

    func testANewerScoutReplacesTheOldOneCompletely() throws {
        let old = work.appendingPathComponent("old.ipa"), output = work.appendingPathComponent("new.ipa")
        try UpdateFixtures.spotifyIPA(at: old, scout: "1.1.1", build: 3)
        XCTAssertTrue(ScoutInjector.needsScout(try ScoutInjector.inspect(ipa: old), version: ScoutVersion("0.1.2", build: 4)), "0.1.2 is newer than 1.1.1")
        let app = try ScoutInjector.inject(ipa: old, framework: UpdateFixtures.framework("0.1.2", build: 4, in: work), to: output)
        XCTAssertEqual(app.scoutVersion, "0.1.2"); XCTAssertEqual(app.scoutBuild, 4)
        let files = try UpdateFixtures.contents(of: output)
        XCTAssertNil(files["Payload/Spotify.app/Frameworks/ScoutKit.framework/Only in 1.1.1.txt"], "nothing of the old Scout is left")
        XCTAssertEqual(try MachOBinary.info(files["Payload/Spotify.app/Spotify"]!).dylibs.filter { $0 == UpdateFixtures.scoutLoad }.count, 1)
        XCTAssertFalse(ScoutInjector.needsScout(app, version: ScoutVersion("1.1.1", build: 3)), "an older Scout isn't put over a newer one")
    }

    func testAnEncryptedIPAIsRefused() throws {
        let ipa = work.appendingPathComponent("enc.ipa")
        try UpdateFixtures.spotifyIPA(at: ipa, encrypted: true)
        XCTAssertTrue(try ScoutInjector.inspect(ipa: ipa).encrypted)
        XCTAssertThrowsError(try ScoutInjector.inject(ipa: ipa, framework: UpdateFixtures.framework("1.0.0", in: work), to: work.appendingPathComponent("o.ipa")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("o.ipa").path), "no half-written IPA")
    }

    func testAnInstalledAppIsPackedWithTheNewScout() throws {
        let app = work.appendingPathComponent("Spotify.app")
        try UpdateFixtures.spotifyIPA(at: work.appendingPathComponent("src.ipa"), scout: "1.0.0")
        // Unpack it into a folder, as the app sits on the phone.
        let reader = try ZipReader(url: work.appendingPathComponent("src.ipa"))
        for entry in reader.entries {
            let target = app.appendingPathComponent(String(entry.name.dropFirst("Payload/Spotify.app/".count)))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try reader.data(of: entry).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.mode & 0o777)], ofItemAtPath: target.path)
        }
        try Data("x".utf8).write(to: app.appendingPathComponent(".hidden"))
        let output = work.appendingPathComponent("packed.ipa")
        let packed = try ScoutInjector.pack(app: app, framework: UpdateFixtures.framework("1.1.0", build: 2, in: work), to: output)
        XCTAssertEqual(packed.scoutVersion, "1.1.0"); XCTAssertTrue(packed.loadsScout); XCTAssertTrue(packed.hasChroma)
        let files = try UpdateFixtures.contents(of: output)
        XCTAssertNil(files["Payload/Spotify.app/Frameworks/ScoutKit.framework/Only in 1.0.0.txt"])
        XCTAssertNil(files["Payload/Spotify.app/.hidden"])
        XCTAssertNotNil(files["Payload/Spotify.app/PlugIns/Widget.appex/Widget"])
        let modes = Dictionary(uniqueKeysWithValues: try ZipReader(url: output).entries.map { ($0.name, $0.mode) })
        XCTAssertEqual(modes["Payload/Spotify.app/Spotify"], 0o100755)
    }
}

@MainActor final class ScoutUpdaterTests: XCTestCase {
    var work: URL!
    var responses: [String: (Data, Int)] = [:]
    override func setUp() async throws { work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    /// An updater running Scout `installed` inside a packed copy of the fixture app.
    func updater(installed: ScoutVersion = ScoutVersion("1.0.0", build: 1)) throws -> ScoutUpdater {
        let app = work.appendingPathComponent("Spotify.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try UpdateFixtures.plist(["CFBundleExecutable": "Spotify", "CFBundleShortVersionString": "9.1.98"]).write(to: app.appendingPathComponent("Info.plist"))
        try UpdateFixtures.machO(dylibs: [UpdateFixtures.scoutLoad]).write(to: app.appendingPathComponent("Spotify"))
        let running = try UpdateFixtures.framework(installed.name, build: installed.build, in: app.appendingPathComponent("Frameworks"))
        let updater = ScoutUpdater(installed: running, appBundle: app, support: work.appendingPathComponent("Support"), documents: work.appendingPathComponent("Docs"))
        updater.get = { [unowned self] url in
            guard let (data, status) = responses[url.absoluteString] else { return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return updater
    }

    /// A release of Scout `version` on the fake GitHub; `sha256` overrides the manifest's checksum.
    /// `build: nil` leaves the build out of the manifest, as releases before 0.1.2 did.
    func publish(_ version: String, build: Int? = 2, sha256: String? = nil) throws {
        let folder = work.appendingPathComponent("release-\(version)")
        let framework = try UpdateFixtures.framework(version, build: build ?? 3, in: folder)
        // Release builds are device binaries: arm64 dylibs.
        let archive = folder.appendingPathComponent("ScoutKit-\(version).zip")
        let writer = try ZipWriter(url: archive)
        for file in try ScoutInjector.files(in: framework) { try writer.add("ScoutKit.framework/" + file.path, data: Data(contentsOf: file.url), mode: file.mode) }
        try writer.finish()
        let zip = try Data(contentsOf: archive)
        let base = "https://github.com/NOTNA9015/Scout/releases/download/v\(version)/"
        var fields: [String: Any] = ["version": version, "spotify": ["9.1.98"],
                                     "framework": ["name": "ScoutKit-\(version).zip", "sha256": sha256 ?? ScoutUpdater.sha256(zip), "size": zip.count]]
        if let build { fields["build"] = build }
        let manifest = try JSONSerialization.data(withJSONObject: fields)
        let release = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v\(version)", "body": "Fixes and more.", "html_url": "https://github.com/NOTNA9015/Scout/releases/tag/v\(version)",
            "assets": [["name": "scout-update.json", "browser_download_url": base + "scout-update.json", "size": manifest.count],
                       ["name": "ScoutKit-\(version).zip", "browser_download_url": base + "ScoutKit-\(version).zip", "size": zip.count]]])
        responses["https://api.github.com/repos/NOTNA9015/Scout/releases/latest"] = (release, 200)
        responses[base + "scout-update.json"] = (manifest, 200)
        responses[base + "ScoutKit-\(version).zip"] = (zip, 200)
    }

    func testANewerReleaseIsDownloadedCheckedAndPacked() async throws {
        let updater = try updater()
        try publish("1.1.0")
        await updater.check()
        guard case .available(let release) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(release.version, "1.1.0"); XCTAssertEqual(release.build, 2); XCTAssertEqual(release.notes, "Fixes and more.")
        await updater.prepare(release)
        guard case .ready(_, let ipa) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(ipa.lastPathComponent, "Spotify \(updater.spotifyVersion) + Scout 1.1.0.ipa")
        let app = try ScoutInjector.inspect(ipa: ipa)
        XCTAssertEqual(app.scoutVersion, "1.1.0"); XCTAssertTrue(app.loadsScout)
        XCTAssertEqual(updater.downloaded?.version, ScoutVersion("1.1.0", build: 2))
        XCTAssertEqual(ScoutInjector.version(ofFramework: updater.newestFramework())?.name, "1.1.0", "IPAs picked in Chroma get the newest Scout")
        // Checking again finds the IPA already made.
        await updater.check()
        guard case .ready = updater.state else { return XCTFail("\(updater.state)") }
    }

    func testABadChecksumIsRefusedAndNothingIsKept() async throws {
        let updater = try updater()
        try publish("1.1.0", sha256: String(repeating: "0", count: 64))
        await updater.check()
        guard case .available(let release) = updater.state else { return XCTFail("\(updater.state)") }
        await updater.prepare(release)
        guard case .failed(let message) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertTrue(message.contains("checksum"), message)
        XCTAssertNil(updater.downloaded)
        XCTAssertTrue(updater.madeIPAs().isEmpty)
    }

    func testUpToDateWhenTheReleaseIsntNewerOrThereIsNone() async throws {
        let updater = try updater(installed: ScoutVersion("1.1.0", build: 2))
        await updater.check()
        XCTAssertEqual(updater.state, .upToDate, "no release yet")
        try publish("1.1.0")
        await updater.check()
        XCTAssertEqual(updater.state, .upToDate)
        try publish("1.1.1", build: nil)
        await updater.check()
        XCTAssertEqual(updater.state, .upToDate, "a release without a build in its manifest is never newer")
    }

    /// Scout's numbers started over at 0.1.2 (build 4) after 1.1.1 (build 3).
    func testZeroOneTwoFollowsOneOneOne() async throws {
        let updater = try updater(installed: ScoutVersion("1.1.1", build: 3))
        try publish("0.1.2", build: 4)
        await updater.check()
        guard case .available(let release) = updater.state else { return XCTFail("\(updater.state)") }
        XCTAssertEqual(release.version, "0.1.2")

        // Once on 0.1.2, a 1.1.1 left in the downloads isn't taken for an update.
        let running = try self.updater(installed: ScoutVersion("0.1.2", build: 4))
        _ = try UpdateFixtures.framework("1.1.1", build: 3, in: work.appendingPathComponent("Support/Updates/1.1.1"))
        XCTAssertNil(running.downloaded)
        XCTAssertEqual(ScoutInjector.version(ofFramework: running.newestFramework())?.name, "0.1.2")
    }

    func testChromasPickerGetsAnIPAWithScoutAndOtherFilesUntouched() async throws {
        let updater = try updater()
        ChromaHook.updater = { updater }
        defer { ChromaHook.updater = { .shared } }
        // A stand-in for Chroma's updater picker delegate.
        let name = "ScoutTestPicker\(UInt32.random(in: 0...UInt32.max))"
        let cls: AnyClass = try XCTUnwrap(objc_allocateClassPair(NSObject.self, name, 0))
        var received: [[URL]] = []
        let block: @convention(block) (AnyObject, AnyObject, NSArray) -> Void = { _, _, urls in received.append(urls.compactMap { $0 as? URL }) }
        class_addMethod(cls, ChromaHook.manySelector, imp_implementationWithBlock(block), "v@:@@")
        objc_registerClassPair(cls)
        XCTAssertTrue(ChromaHook.attach(to: name))
        let delegate = (cls as! NSObject.Type).init()

        // A certificate goes through at once, as picked.
        let certificate = work.appendingPathComponent("cert.p12"); try Data("p12".utf8).write(to: certificate)
        _ = delegate.perform(ChromaHook.manySelector, with: NSObject(), with: [certificate] as NSArray)
        XCTAssertEqual(received.last, [certificate])

        // A clean Spotify IPA comes back as a copy with Scout in it.
        let clean = work.appendingPathComponent("Spotify 9.1.98.ipa")
        try UpdateFixtures.spotifyIPA(at: clean)
        _ = delegate.perform(ChromaHook.manySelector, with: NSObject(), with: [clean] as NSArray)
        for _ in 0..<200 where received.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let handed = try XCTUnwrap(received.last?.first)
        XCTAssertNotEqual(handed, clean)
        XCTAssertEqual(handed.deletingLastPathComponent().lastPathComponent, "Scout IPAs")
        XCTAssertEqual(try ScoutInjector.inspect(ipa: handed).scoutVersion, "1.0.0")
        XCTAssertNil(try ScoutInjector.inspect(ipa: clean).scoutVersion, "the picked file isn't changed")

        // An IPA that already has this Scout goes through as it is.
        _ = delegate.perform(ChromaHook.manySelector, with: NSObject(), with: [handed] as NSArray)
        XCTAssertEqual(received.last, [handed])
    }
}

final class ScoutAccentTests: XCTestCase {
    func testChromasStoredAccentIsRead() {
        XCTAssertEqual(ScoutAccent.parse(NSNumber(value: 16395592)), 0xFA2D48, "Chroma stores an RGB integer (Apple Music red)")
        XCTAssertEqual(ScoutAccent.parse("#37F200"), 0x37F200)
        XCTAssertEqual(ScoutAccent.parse("1ed760"), 0x1ED760)
        XCTAssertNil(ScoutAccent.parse("green")); XCTAssertNil(ScoutAccent.parse(NSNumber(value: -1))); XCTAssertNil(ScoutAccent.parse(nil))
    }

    func testTextOnTheAccentStaysReadable() {
        XCTAssertTrue(ScoutAccent.prefersBlackText(0x37F200), "Chroma's lime")
        XCTAssertTrue(ScoutAccent.prefersBlackText(0x1ED760), "Spotify green")
        XCTAssertFalse(ScoutAccent.prefersBlackText(0xFA2D48), "Apple Music red")
        XCTAssertFalse(ScoutAccent.prefersBlackText(0x2F5BF5), "a dark blue")
    }

    func testTheTestHostUsesSpotifyGreen() {
        XCTAssertEqual(ScoutAccent.rgb(), ScoutAccent.spotifyGreen)
    }
}
