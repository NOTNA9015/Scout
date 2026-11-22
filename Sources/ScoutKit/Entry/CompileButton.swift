import UIKit

/// The Compile pending playlists button, floating at the bottom of Spotify's Local Files page.
/// It turns every imported album that isn't a playlist yet into one.
@MainActor enum CompileButton {
    static let id = "scout.compile"

    static func place(in controller: UIViewController) {
        guard let root = controller.viewIfLoaded, root.window != nil else { return }
        if let existing = ScoutEntry.find(root.window ?? root, id: id) as? UIButton { refresh(existing); return }
        let button = FloatingPill.make(id: id, title: "Compile pending playlists", symbol: "music.note.list", placement: .center, in: root)
        button.addAction(UIAction { [weak button, weak controller] _ in
            guard let button, let controller else { return }
            compile(button, from: controller)
        }, for: .touchUpInside)
        refresh(button)
    }

    static func refresh(_ button: UIButton) {
        FloatingPill.lift(button)
        ScoutLibrary.shared.forgetMissingFiles()
        let count = ScoutLibrary.shared.waiting.count
        button.configuration?.title = count == 0 ? "Compile pending playlists" : "Compile pending playlists (\(count))"
        button.configuration?.showsActivityIndicator = false
        button.isEnabled = true
    }

    static func compile(_ button: UIButton, from controller: UIViewController) {
        let library = ScoutLibrary.shared
        library.forgetMissingFiles(); refresh(button)
        guard !library.waiting.isEmpty else {
            tell(controller, "No playlists waiting", "Albums you import with Scout show up here until they're made into playlists.")
            return
        }
        button.isEnabled = false
        button.configuration?.title = "Compiling…"
        button.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            let result = await library.compileWaiting()
            refresh(button)
            var lines: [String] = []
            if !result.made.isEmpty { lines.append("Made: " + result.made.map(\.name).joined(separator: ", ")) }
            for plan in result.failed { lines.append("\(plan.name): \(plan.lastError ?? "Couldn't make the playlist.")") }
            let title = result.failed.isEmpty ? (result.made.count == 1 ? "Playlist made" : "\(result.made.count) playlists made")
                : result.made.isEmpty ? "Couldn't make the playlists" : "Some playlists weren't made"
            tell(controller, title, lines.joined(separator: "\n\n"), open: result.made.count == 1 ? result.made[0].playlistURI : nil)
        }
    }

    static func tell(_ controller: UIViewController, _ title: String, _ message: String, open uri: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let uri { alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in SpotifyLinks.open(uri) }) }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        var top: UIViewController = controller
        while let next = top.presentedViewController { top = next }
        top.present(alert, animated: true)
    }
}
