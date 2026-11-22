import Foundation
import CryptoKit

/// Scout's own updates, separate from Chroma's: releases on github.com/NOTNA9015/Scout carry
/// Scout's framework and nothing of Spotify's or Chroma's. Scout downloads it, checks it, and packs
/// this app with it into an IPA in Files → Spotify → Scout IPAs. Chroma's Update tab installs that
/// IPA like any Spotify IPA (signed with your certificate, over this app, keeping your data).
@MainActor public final class ScoutUpdater: ObservableObject {
    public static let shared = ScoutUpdater()
    public static let repository = "NOTNA9015/Scout"
    static let manifestName = "scout-update.json"
    static let checkedKey = "scout.update.checked"

    public struct Release: Equatable {
        public var version: String
        /// Releases are ordered by build, not by name (see ScoutVersion).
        public var build: Int
        public var notes: String
        public var page: URL
        public var framework: URL
        public var sha256: String
        public var size: Int
        /// The Spotify versions it was built for.
        public var spotify: [String]
    }
    public enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        /// What is happening and how far along (0…1).
        case working(String, Double)
        /// The IPA to install.
        case ready(Release, URL)
        case failed(String)
    }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastChecked: Date?

    /// GET, swappable for tests.
    var get: (URL) async throws -> (Data, HTTPURLResponse) = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Scout-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScoutError.message("No answer from GitHub.") }
        return (data, http)
    }
    /// The ScoutKit.framework running now, the app it runs in, and where Scout keeps updates.
    let installed: URL
    let appBundle: URL
    let updatesFolder: URL
    /// Files → On My iPhone → Spotify → Scout IPAs.
    public let outputFolder: URL

    init(installed: URL = Bundle(for: ScoutEntry.self).bundleURL, appBundle: URL = Bundle.main.bundleURL,
         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scout", isDirectory: true),
         documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.installed = installed; self.appBundle = appBundle
        updatesFolder = support.appendingPathComponent("Updates", isDirectory: true)
        outputFolder = documents.appendingPathComponent("Scout IPAs", isDirectory: true)
        lastChecked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date
    }

    public var installedVersion: ScoutVersion { ScoutInjector.version(ofFramework: installed) ?? ScoutVersion("0", build: 0) }
    public var currentVersion: String { installedVersion.name }
    public var spotifyVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var busy: Bool { if case .working = state { return true }; return state == .checking }

    /// A downloaded update newer than the Scout running, if there is one.
    public var downloaded: (version: ScoutVersion, framework: URL)? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: updatesFolder, includingPropertiesForKeys: nil)) ?? []
        let running = installedVersion
        return folders.compactMap { folder -> (ScoutVersion, URL)? in
            let framework = folder.appendingPathComponent("ScoutKit.framework")
            guard let version = ScoutInjector.version(ofFramework: framework), version.isNewer(than: running) else { return nil }
            return (version, framework)
        }.max { $0.0.build < $1.0.build }
    }
    /// What Scout puts into IPAs: the newest Scout on this phone.
    public func newestFramework() -> URL { downloaded?.framework ?? installed }

    // MARK: Checking

    /// At most twice a day, when Scout opens.
    public func checkIfDue() {
        guard !busy, lastChecked.map({ Date().timeIntervalSince($0) > 12 * 3600 }) ?? true else { return }
        Task { await check() }
    }

    public func check() async {
        guard !busy else { return }
        state = .checking
        do {
            let release = try await latestRelease()
            lastChecked = Date(); UserDefaults.standard.set(lastChecked, forKey: Self.checkedKey)
            guard let release, release.build > installedVersion.build else { state = .upToDate; return }
            if let ipa = preparedIPA(version: release.version) { state = .ready(release, ipa) } else { state = .available(release) }
        } catch {
            state = .failed("Couldn't check for updates. \(error.localizedDescription)")
        }
    }

    /// The latest release on GitHub; nil when there is none yet.
    func latestRelease() async throws -> Release? {
        struct GitHubRelease: Decodable {
            var tag_name: String; var body: String?; var html_url: URL; var assets: [Asset]
            struct Asset: Decodable { var name: String; var browser_download_url: URL; var size: Int }
        }
        struct Manifest: Decodable {
            var version: String; var build: Int?; var framework: File; var spotify: [String]?
            struct File: Decodable { var name: String; var sha256: String; var size: Int }
        }
        let (data, response) = try await get(URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw ScoutError.message(response.statusCode == 403 ? "GitHub is limiting requests; try again in an hour." : "GitHub answered \(response.statusCode).") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let manifestAsset = release.assets.first(where: { $0.name == Self.manifestName }) else {
            throw ScoutError.message("Release \(release.tag_name) has no \(Self.manifestName).")
        }
        let (manifestData, manifestResponse) = try await get(manifestAsset.browser_download_url)
        guard manifestResponse.statusCode == 200 else { throw ScoutError.message("Couldn't read release \(release.tag_name) (\(manifestResponse.statusCode)).") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard let asset = release.assets.first(where: { $0.name == manifest.framework.name }) else {
            throw ScoutError.message("Release \(release.tag_name) is missing \(manifest.framework.name).")
        }
        // Releases made before builds were in the manifest count as build 0, older than any Scout.
        return Release(version: manifest.version, build: manifest.build ?? 0, notes: release.body ?? "", page: release.html_url, framework: asset.browser_download_url,
                       sha256: manifest.framework.sha256.lowercased(), size: manifest.framework.size, spotify: manifest.spotify ?? [])
    }

    // MARK: Preparing

    /// Downloads the release's Scout, checks it, and packs this app with it into an IPA.
    public func prepare(_ release: Release) async {
        guard !busy else { return }
        state = .working("Downloading Scout \(release.version)", 0)
        do {
            let framework = try await download(release)
            let output = outputFolder.appendingPathComponent("Spotify \(spotifyVersion) + Scout \(release.version).ipa")
            state = .working("Building the update", 0)
            let app = appBundle
            _ = try await Task.detached(priority: .userInitiated) { [weak self] in
                try ScoutInjector.pack(app: app, framework: framework, to: output) { fraction in
                    Task { @MainActor in self?.state = .working("Building the update", fraction) }
                }
            }.value
            state = .ready(release, output)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The release's framework, unpacked into Updates/<version>/ScoutKit.framework once its size,
    /// checksum, version and architecture are right.
    func download(_ release: Release) async throws -> URL {
        let (data, response) = try await get(release.framework)
        guard response.statusCode == 200 else { throw ScoutError.message("The download failed (\(response.statusCode)).") }
        guard data.count == release.size, Self.sha256(data) == release.sha256 else {
            throw ScoutError.message("The download doesn't match the release's checksum. Try again.")
        }
        let folder = updatesFolder.appendingPathComponent(release.version, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("ScoutKit.zip")
        try data.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        do {
            try Self.unpack(archive, into: folder, only: "ScoutKit.framework/")
            let framework = folder.appendingPathComponent("ScoutKit.framework")
            guard let version = ScoutInjector.version(ofFramework: framework), version == ScoutVersion(release.version, build: release.build) else {
                throw ScoutError.message("The download isn't Scout \(release.version).")
            }
            guard Self.isIPhoneBinary(framework.appendingPathComponent("ScoutKit")) else { throw ScoutError.message("The download isn't built for iPhone.") }
            return framework
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// An IPA Scout already made for this version, from an earlier try.
    func preparedIPA(version: String) -> URL? {
        let url = outputFolder.appendingPathComponent("Spotify \(spotifyVersion) + Scout \(version).ipa")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Scout (the newest on this phone) added to a Spotify IPA, written to Scout IPAs. The picked
    /// file isn't changed.
    public func addScout(toIPA source: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let framework = newestFramework()
        guard let version = ScoutInjector.version(ofFramework: framework) else { throw ScoutInjector.Failure.noFramework }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let app = try ScoutInjector.inspect(ipa: source)
        guard app.isSpotify else { throw ScoutError.message("This IPA is \(app.executable), not Spotify.") }
        if app.encrypted { throw MachOBinary.Failure.encrypted }
        var output = outputFolder.appendingPathComponent("Spotify \(app.version ?? "") + Scout \(version.name).ipa")
        if output.standardizedFileURL == source.standardizedFileURL { output = outputFolder.appendingPathComponent("Spotify \(app.version ?? "") + Scout \(version.name) (2).ipa") }
        let target = output
        _ = try await Task.detached(priority: .userInitiated) {
            try ScoutInjector.inject(ipa: source, framework: framework, to: target) { fraction in Task { @MainActor in progress(fraction) } }
        }.value
        return output
    }

    /// The IPAs Scout made, newest first, and their total size.
    public func madeIPAs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "ipa" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
    public func deleteMadeIPAs() {
        for url in madeIPAs() { try? FileManager.default.removeItem(at: url) }
        if case .ready = state { state = .idle }
    }

    // MARK: Helpers

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A 64-bit ARM Mach-O (the device build, not the simulator's or a Mac's).
    static func isIPhoneBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 32), head.count == 32 else { return false }
        try? handle.close()
        return head.u32(0) == MachOBinary.magic64 && head.u32(4) == 0x0100_000C && head.u32(12) == 6   // arm64, MH_DYLIB
    }

    /// Unpacks the entries under `prefix`, refusing paths that would leave `folder`.
    static func unpack(_ archive: URL, into folder: URL, only prefix: String) throws {
        let reader = try ZipReader(url: archive)
        let entries = reader.entries.filter { $0.name.hasPrefix(prefix) }
        guard !entries.isEmpty else { throw ScoutError.message("The download has no \(prefix.dropLast()).") }
        for entry in entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.name.hasPrefix("/"), !parts.contains(".."), !entry.isSymlink else { throw ScoutError.message("The download has an unsafe file (\(entry.name)).") }
            let target = folder.appendingPathComponent(entry.name)
            if entry.isDirectory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try reader.read(entry) { try handle.write(contentsOf: $0) }
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: entry.mode & 0o777)], ofItemAtPath: target.path)
        }
    }
}
