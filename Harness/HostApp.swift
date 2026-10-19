import UIKit
import AVFoundation
import ScoutKit

/// Stand-in for Spotify in the simulator: a "Your Library" page whose header has the same
/// accessibility id Spotify uses, plus offline fixtures for downloads, catalog and lyrics.
@main final class HostApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-ScoutFixtures") { Fixtures.install() }
        if ProcessInfo.processInfo.arguments.contains("-ScoutSearchFixtures") { Fixtures.installSearch() }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: HarnessYourLibraryViewController())
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class HarnessYourLibraryViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let title = UILabel(); title.text = "Your Library"; title.font = .boldSystemFont(ofSize: 24); title.textColor = .white
        let search = UIButton(type: .system); search.setImage(UIImage(systemName: "magnifyingglass"), for: .normal); search.tintColor = .white
        let add = UIButton(type: .system); add.setImage(UIImage(systemName: "plus"), for: .normal); add.tintColor = .white
        let buttons = UIStackView(arrangedSubviews: [search, add]); buttons.spacing = 8
        buttons.accessibilityIdentifier = "Components.Header.UI.Toolbar.ButtonContainer"
        let header = UIStackView(arrangedSubviews: [title, UIView(), buttons]); header.axis = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                                     header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                                     header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)])
        let localFiles = UIButton(type: .system); localFiles.setTitle("Local Files", for: .normal); localFiles.accessibilityIdentifier = "harness.localfiles"
        localFiles.addAction(UIAction { [weak self] _ in self?.navigationController?.pushViewController(HarnessLocalFilesViewController(), animated: true) }, for: .touchUpInside)
        localFiles.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(localFiles)
        NSLayoutConstraint.activate([localFiles.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                                     localFiles.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24)])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
}

/// Spotify's Local Files page, as far as Scout can tell: a page titled "Local Files".
final class HarnessLocalFilesViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Local Files"
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
}

/// Makes every playlist at once, as Spotify would.
struct FixturePublisher: PlaylistPublishing {
    func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan {
        var plan = plan; plan.status = .published; plan.playlistURI = "spotify:playlist:fixture"; plan.lastError = nil; return plan
    }
}

/// Offline data so every step can be exercised without the network.
enum Fixtures {
    @MainActor static func installSearch() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchFixtureProtocol.self]
        ScoutEntry.searchService = ScoutService(session: URLSession(configuration: config), previewLoader: { track, folder in
            try await Task.sleep(for: .milliseconds(1500))
            let file = folder.appendingPathComponent("preview.wav")
            tone(file, frequency: 440, seconds: 30)
            return await DownloadedSong.make(file: file, source: track, artwork: nil)
        })
        ScoutEntry.catalog = FixtureCatalog(); ScoutEntry.lyrics = FixtureLyrics(); ScoutEntry.listener = FixtureListener()
    }
    @MainActor static func install() {
        ScoutEntry.catalog = FixtureCatalog()
        ScoutEntry.lyrics = FixtureLyrics()
        ScoutEntry.listener = FixtureListener()
        ScoutEntry.fixtureSongs = { await songs() }
        ScoutLibrary.shared.publisher = FixturePublisher()
    }
    static func songs() async -> [DownloadedSong] {
        var result: [DownloadedSong] = []
        try? FileManager.default.createDirectory(at: DownloadedSong.stagingRoot, withIntermediateDirectories: true)
        for (index, (title, artist)) in [("Night Bus (feat. Juno Reyes) [CDQ]", "Ines Vale"), ("Paper Boats", "Ines Vale & Low Orchard"), ("Salt and Cedar", "Ines Vale")].enumerated() {
            let file = DownloadedSong.stagingRoot.appendingPathComponent(UUID().uuidString + ".wav")
            tone(file, frequency: 330 + Double(index) * 110)
            let source = ScoutTrack(title: title, artist: artist, album: "The Quiet Hours", trackNumber: index + 1, audioURL: "https://example.invalid/\(index).wav")
            result.append(await DownloadedSong.make(file: file, source: source, artwork: nil))
        }
        return result
    }
    static func tone(_ url: URL, frequency: Double, seconds: Int = 1) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frames = AVAudioFrameCount(44100 * seconds)
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * frequency * Double(i) / 44100) * 0.1) }
        try? file.write(from: buffer)
    }
}

private final class SearchFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if request.url?.path == "/fixture-songs" {
            let header = "<tr><td>Era</td><td>Name</td><td>Track Length</td><td>Available Length</td><td>Quality</td><td>Link(s)</td></tr>"
            body = "<table>" + header + (0..<40).map { index in
                let title = index == 0 ? "Ghost Town [V1]" : index == 1 ? "Runaway [V2]" : "Song \(index)"
                return "<tr><td>Donda</td><td>\(title)</td><td>0:30</td><td>Full</td><td>High Quality</td><td><a href=\"https://example.com/song-\(index).mp3\">Listen</a></td></tr>"
            }.joined() + "</table>"
        } else { body = #"items.push({name: "Unreleased", pageUrl: "/fixture-songs"});"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct FixtureCatalog: CatalogSearching {
    func songs(_ term: String) async -> [CatalogMatch] {
        [CatalogMatch(title: "Night Bus", artists: ["Ines Vale", "Juno Reyes"], album: "The Quiet Hours", coverURL: nil, source: "Fixture"),
         CatalogMatch(title: "Night Bus (Demo)", artists: ["Ines Vale"], album: "Overpass", coverURL: nil, source: "Fixture")]
    }
    func albums(_ term: String) async -> [CatalogMatch] { [CatalogMatch(title: "The Quiet Hours", artists: ["Ines Vale"], album: "The Quiet Hours", coverURL: nil, source: "Fixture")] }
    func artists(_ term: String) async -> [String] { ["Ines Vale", "Juno Reyes", "Low Orchard"] }
}

struct FixtureLyrics: LyricsSearching {
    func candidates(title: String, artists: [String], duration: Double) async -> [LyricCandidate] {
        // The second song has none, to exercise the "generate?" prompt.
        guard !title.localizedCaseInsensitiveContains("Paper") else { return [] }
        return [LyricCandidate(id: "a", source: "Fixture", title: title, artist: artists.first ?? "", duration: 1, text: "[00:00.10]First line here\n[00:00.60]Second line here"),
                LyricCandidate(id: "b", source: "Fixture", title: title, artist: artists.first ?? "", duration: nil, text: "First line here\nSecond line here")]
    }
}

/// "Hears" the fixture lyrics, so the recommendation can be checked without a speech model.
struct FixtureListener: AudioListening {
    func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
        try await Task.sleep(for: .milliseconds(300))
        return "first line here second line here".split(separator: " ").enumerated().map { index, word in
            TimedLyricWord(start: 0.1 + Double(index) * 0.12, end: 0.2 + Double(index) * 0.12, text: String(word))
        }
    }
}
