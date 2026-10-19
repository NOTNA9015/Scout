import UIKit

/// The Compile pending playlists button, floating at the bottom of Spotify's Local Files page.
/// It turns every imported album that isn't a playlist yet into one.
@MainActor enum CompileButton {
    static let id = "scout.compile"

    static func place(in controller: UIViewController) {
        guard let root = controller.viewIfLoaded, root.window != nil else { return }
        if let existing = ScoutEntry.find(root.window ?? root, id: id) as? UIButton { refresh(existing); return }
        let button = UIButton(configuration: .filled())
        button.accessibilityIdentifier = id
        button.configuration?.cornerStyle = .capsule
        button.configuration?.baseBackgroundColor = UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
        button.configuration?.baseForegroundColor = .black
        button.configuration?.image = UIImage(systemName: "music.note.list")
        button.configuration?.imagePadding = 8
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.4; button.layer.shadowRadius = 10
        button.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(button)
        let bottom = button.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        bottom.identifier = "scout.compile.bottom"
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom,
            button.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
        ])
        button.addAction(UIAction { [weak button, weak controller] _ in
            guard let button, let controller else { return }
            compile(button, from: controller)
        }, for: .touchUpInside)
        refresh(button)
        // The mini player comes and goes with playback; follow it while the page is shown.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak button] timer in
            MainActor.assumeIsolated {
                guard let button, button.superview != nil else { timer.invalidate(); return }
                if button.window != nil { UIView.animate(withDuration: 0.2) { lift(button); button.superview?.layoutIfNeeded() } }
            }
        }
    }

    static func refresh(_ button: UIButton) {
        button.superview?.bringSubviewToFront(button)
        lift(button)
        ScoutLibrary.shared.forgetMissingFiles()
        let count = ScoutLibrary.shared.waiting.count
        button.configuration?.title = count == 0 ? "Compile pending playlists" : "Compile pending playlists (\(count))"
        button.configuration?.showsActivityIndicator = false
        button.isEnabled = true
    }

    /// Sits just above whatever covers the bottom of the page: Spotify's mini player and tab bar
    /// (found by their class names), or the safe area when there are none.
    static func lift(_ button: UIButton) {
        guard let root = button.superview, let window = root.window,
              let bottom = root.constraints.first(where: { $0.identifier == "scout.compile.bottom" }) else { return }
        let rootBottom = root.convert(root.bounds, to: window).maxY
        var cover = window.bounds.maxY - window.safeAreaInsets.bottom
        var queue: [UIView] = [window], seen = 0
        while !queue.isEmpty && seen < 4000 {
            let view = queue.removeFirst(); seen += 1
            guard !view.isHidden, view.alpha > 0.01, view !== root else { continue }
            let name = NSStringFromClass(type(of: view)).lowercased()
            if ["miniplayer", "nowplayingbar", "tabbar", "bottombar", "playerbar"].contains(where: name.contains) {
                let frame = view.convert(view.bounds, to: window)
                if frame.width >= window.bounds.width * 0.6, frame.height < 260, frame.maxY >= window.bounds.maxY - 300 { cover = min(cover, frame.minY) }
                continue
            }
            queue += view.subviews
        }
        bottom.constant = -(max(0, rootBottom - cover) + 12)
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
