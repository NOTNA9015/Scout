import UIKit
import SwiftUI

/// How Scout is reached inside Spotify (with spoti.pw): a pill floating over Your Library, and
/// shaking the phone anywhere. Nothing of Spotify's or spoti.pw's is replaced.
@objc(ScoutEntry) public final class ScoutEntry: NSObject {
    static let buttonID = "scout.entry"

    /// Swappable for the test host: what the flow downloads with, looks up and saves to.
    @MainActor public static var fetcher: @MainActor () -> SongFetching = { ScoutService.shared }
    @MainActor public static var searchService: ScoutService = .shared
    @MainActor public static var catalog: CatalogSearching = CatalogSearch()
    @MainActor public static var lyrics: LyricsSearching = LyricsSearch()
    @MainActor public static var library: ScoutLibrary { .shared }
    @MainActor public static var listener: AudioListening = OnDeviceListener()
    /// Test host only: songs to start with instead of searching.
    @MainActor public static var fixtureSongs: (@MainActor () async -> [DownloadedSong])?

    /// At launch (Bootstrap.m). Inside Spotify, albums become real playlists when the user taps
    /// Compile pending playlists on the Local Files page, and Scout keeps itself in the Spotify IPAs
    /// added in Chroma's Update tab.
    @MainActor @objc public static func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil else { return }
        let library = ScoutLibrary.shared
        library.publisher = SpotifyPlaylistPublisher(musicFolder: library.musicFolder)
        ChromaHook.attach()
        #if targetEnvironment(simulator)
        openForPreview()
        #endif
    }

    #if targetEnvironment(simulator)
    /// Simulator only (there's no shake from the command line): `simctl launch … -ScoutOpen menu`
    /// or `-ScoutOpen updates` opens Scout once Spotify is on screen.
    @MainActor static func openForPreview() {
        guard let what = UserDefaults.standard.string(forKey: "ScoutOpen") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
                  var top = window.rootViewController else { return }
            while let next = top.presentedViewController { top = next }
            if what == "updates" {
                let host = UIHostingController(rootView: UpdatesView(updater: .shared))
                host.overrideUserInterfaceStyle = .dark
                host.view.tintColor = UIColor(Color.scoutAccent)
                top.present(host, animated: true)
            } else {
                present(from: window)
            }
        }
    }
    #endif
    /// Called after every view controller appears (Bootstrap.m). Cheap unless it is a Your Library
    /// or Local Files page, or Chroma's updater (ChromaUpdates).
    @MainActor @objc public static func attach(to controller: UIViewController) {
        ChromaUpdates.attach(to: controller)
        if NSStringFromClass(type(of: controller)).contains("YourLibrary") {
            place(in: controller)
            // Spotify lays the page out after it appears; try again once it has.
            for delay in [0.4, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in if let controller { place(in: controller) } } }
        }
        for delay in [0.0, 0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak controller] in
                guard let controller, controller.viewIfLoaded?.window != nil else { return }
                if delay == 0.5 { PageLog.note(controller) }
                if let page = localFilesPage(from: controller, deep: delay > 0) { CompileButton.place(in: page) }
            }
        }
    }

    /// Spotify's Local Files page: by its page URI or id, a class name, or its title; checked on
    /// the controller and the controllers around it.
    static let localFilesTitles: Set<String> = ["local files", "lokale filer", "lokala filer", "lokale dateien", "fichiers locaux", "archivos locales", "file locali", "lokale bestanden", "arquivos locais", "lokalne pliki", "paikalliset tiedostot"]
    @MainActor static func localFilesPage(from controller: UIViewController, deep: Bool) -> UIViewController? {
        var chain: [UIViewController] = [], next: UIViewController? = controller
        while let current = next { chain.append(current); next = current.parent }
        for candidate in chain where !(candidate is UINavigationController) && !(candidate is UITabBarController) {
            if isLocalFiles(candidate) { return pageController(candidate) }
        }
        // Spotify's Local Files header view, somewhere in the page (never Your Library itself).
        let page = pageController(controller)
        if deep, !chain.contains(where: { NSStringFromClass(type(of: $0)).contains("YourLibrary") }),
           let root = page.viewIfLoaded, contains(root, classNamed: "localfiles") { return page }
        return nil
    }
    /// The page a controller belongs to: the one sitting directly in a navigation stack.
    @MainActor static func pageController(_ controller: UIViewController) -> UIViewController {
        var current = controller
        while let parent = current.parent, !(parent is UINavigationController), !(parent is UITabBarController) { current = parent }
        return current
    }
    @MainActor static func isLocalFiles(_ controller: UIViewController) -> Bool {
        let text = PageLog.identity(controller).lowercased()
        if text.contains("localfiles") || text.contains("local-files") || text.contains("local_files") { return true }
        let titles = [controller.navigationItem.title, controller.title, controller.navigationItem.titleView.flatMap { ($0 as? UILabel)?.text }]
        return titles.contains { localFilesTitles.contains(($0 ?? "").trimmingCharacters(in: .whitespaces).lowercased()) }
    }
    @MainActor static func contains(_ view: UIView, classNamed part: String) -> Bool {
        var queue = [view], seen = 0
        while !queue.isEmpty && seen < 600 {
            let current = queue.removeFirst(); seen += 1
            if NSStringFromClass(type(of: current)).lowercased().contains(part) { return true }
            queue += current.subviews
        }
        return false
    }

    /// A "Scout" pill floating at the bottom right of Your Library, apart from Spotify's own search
    /// and + buttons in the header.
    @MainActor static func place(in controller: UIViewController) {
        let page = pageController(controller)
        guard let root = page.viewIfLoaded, let window = root.window, root.bounds.width >= window.bounds.width * 0.8 else { return }
        if let existing = find(root, id: buttonID) as? UIButton { FloatingPill.lift(existing); return }
        let button = FloatingPill.make(id: buttonID, title: "Scout", symbol: "sparkles", placement: .trailing, in: root)
        button.accessibilityLabel = "Scout"
        button.addAction(UIAction { [weak button] _ in present(from: button?.window) }, for: .touchUpInside)
    }
    static func find(_ view: UIView, id: String, depth: Int = 0) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        guard depth < 30 else { return nil }
        for sub in view.subviews { if let hit = find(sub, id: id, depth: depth + 1) { return hit } }
        return nil
    }

    /// Shake anywhere (Bootstrap.m) or the Scout pill.
    @MainActor @objc public static func present(from window: UIWindow?) {
        guard let window = window ?? UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        if top is ScoutHostController { return }
        let host = ScoutHostController()
        top.present(host, animated: true)
    }
}

/// Starts as the small menu and grows to full height once an import begins.
final class ScoutHostController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(EmptyView()))
        modalPresentationStyle = .pageSheet
        overrideUserInterfaceStyle = .dark
        // Chroma's accent for everything UIKit tints too. Spotify sets its green on every text field
        // and text view through their appearance, so Scout's own are set the same way, only in Scout.
        let accent = UIColor(Color.scoutAccent)
        view.tintColor = accent
        UITextField.appearance(whenContainedInInstancesOf: [ScoutHostController.self]).tintColor = accent
        UITextView.appearance(whenContainedInInstancesOf: [ScoutHostController.self]).tintColor = accent
        let menu = UISheetPresentationController.Detent.Identifier("scout.menu")
        ScoutLibrary.shared.forgetMissingFiles()
        Task { await ScoutLibrary.shared.removeDuplicates() }
        // Taller when there are playlists to compile (another card and its result).
        sheetPresentationController?.detents = [.custom(identifier: menu) { _ in ScoutLibrary.shared.waiting.isEmpty ? 650 : 790 }, .large()]
        sheetPresentationController?.prefersGrabberVisible = true
        rootView = AnyView(ScoutRootView(fetcher: ScoutEntry.fetcher, catalog: ScoutEntry.catalog, lyrics: ScoutEntry.lyrics, library: ScoutEntry.library, listener: ScoutEntry.listener,
                                         autoBegin: ScoutEntry.fixtureSongs,
                                         expand: { [weak self] in
                                             guard let sheet = self?.sheetPresentationController else { return }
                                             sheet.animateChanges { sheet.detents = [.large()]; sheet.selectedDetentIdentifier = .large }
                                             self?.isModalInPresentation = true
                                         },
                                         close: { [weak self] in self?.dismiss(animated: true) }))
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
