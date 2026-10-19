import UIKit
import Combine

/// Shows the playlists Scout made from albums as albums, only in how Spotify displays them:
/// a row whose title is a Scout album and whose subtitle says "Playlist • <owner>" reads
/// "Album • <artists>" instead, and its picture is the album's cover. The playlist itself is
/// unchanged in Spotify. Driven by the label and image hooks in Bootstrap.m.
@objc(ScoutAlbumDisplay) public final class AlbumDisplay: NSObject {
    struct Album {
        var subtitle: String          // "Frank Ocean, André 3000"
        var coverFile: URL?
        var playlistURI: String?
    }
    /// Scout albums that are playlists in Spotify, by the playlist's name there.
    @MainActor static var albums: [String: Album] = [:]
    @MainActor private static var covers: [URL: UIImage] = [:]
    @MainActor private static var watching: AnyCancellable?
    /// Image views showing a Scout cover, with the picture Spotify last gave each.
    @MainActor private static let showing = NSMapTable<UIImageView, UIImage>.weakToStrongObjects()
    @MainActor private static var queued = NSHashTable<UIView>.weakObjects()
    @MainActor private static var busy = false

    /// Words Spotify puts before the owner in a playlist's subtitle, lowercased.
    static let playlistWords: Set<String> = ["playlist", "public playlist", "playliste", "spilleliste", "spellista", "soittolista",
                                             "afspeellijst", "lista", "playlista", "lista de reprodução", "lista de reproducción"]
    static let separators = [" • ", " · ", " ∙ "]

    @MainActor public static func start(library: ScoutLibrary) {
        watching = library.$playlists.combineLatest(library.$songs).receive(on: RunLoop.main).sink { plans, _ in
            MainActor.assumeIsolated { index(plans, coverFolder: library.supportFolder.appendingPathComponent("Covers")) }
        }
    }
    @MainActor static func index(_ plans: [PlaylistPlan], coverFolder: URL) {
        albums = [:]
        for plan in plans where plan.playlistURI != nil {
            let album = Album(subtitle: Suggestions.joinArtists(plan.artists), coverFile: plan.coverFilename.map { coverFolder.appendingPathComponent($0) },
                              playlistURI: plan.playlistURI)
            albums[key(plan.spotifyName ?? plan.name)] = album
        }
        covers = covers.filter { url, _ in albums.values.contains { $0.coverFile == url } }
    }
    static func key(_ text: String) -> String { AlbumKey.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// "Playlist • Anton" → "Album • Frank Ocean"; nil when the text isn't a playlist subtitle.
    static func albumSubtitle(for text: String, artists: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = separators.first { trimmed.contains($0) }
        let kind = separator.map { String(trimmed.components(separatedBy: $0)[0]) } ?? trimmed
        guard playlistWords.contains(kind.lowercased()) else { return nil }
        guard let separator, !artists.isEmpty else { return "Album" }
        return "Album" + separator + artists
    }

    // MARK: Hooks (Bootstrap.m)

    /// A label's text changed: look at its row once the row has finished filling in.
    @MainActor @objc public static func labelChanged(_ label: UILabel) {
        guard !busy, !albums.isEmpty, let text = label.text, !text.isEmpty, text.count < 300 else { return }
        let lowered = text.lowercased()
        guard albums[key(text)] != nil || playlistWords.contains(where: lowered.hasPrefix) else { return }
        let row = container(of: label)
        if queued.contains(row) { return }
        queued.add(row)
        DispatchQueue.main.async { queued.remove(row); refresh(row) }
    }
    /// Spotify is setting a picture: keep the Scout cover on a Scout album's row, and hand back
    /// Spotify's own picture once the row shows something else.
    @MainActor @objc public static func image(for view: UIImageView, proposed: UIImage?) -> UIImage? {
        guard !busy, showing.object(forKey: view) != nil else { return proposed }
        showing.setObject(proposed ?? UIImage(), forKey: view)
        if let album = album(in: container(of: view)), let cover = cover(album) { return cover }
        showing.removeObject(forKey: view)
        return proposed
    }
    /// A playlist page appeared: if it is one Scout made, show its cover and call it an album.
    @MainActor static func attach(to page: UIViewController) {
        guard !albums.isEmpty, let root = page.viewIfLoaded else { return }
        let identity = PageLog.identity(page)
        guard let album = albums.values.first(where: { $0.playlistURI.map(identity.contains) == true }) else { return }
        relabel(root, album: album, limit: 400)
        // The header's picture: the biggest roughly square image near the top of the page.
        let images = views(in: root, limit: 400).compactMap { $0 as? UIImageView }.filter {
            let frame = $0.convert($0.bounds, to: root)
            return frame.width >= 120 && abs(frame.width - frame.height) < 8 && frame.minY < root.bounds.height * 0.6
        }
        if let header = images.max(by: { $0.bounds.width < $1.bounds.width }) { show(album, in: header) }
    }

    // MARK: Rows

    @MainActor static func refresh(_ row: UIView) {
        if let album = album(in: row) {
            relabel(row, album: album, limit: 60)
            if let picture = picture(in: row) { show(album, in: picture) }
        } else {
            // Reused for something else: give back what Spotify last set.
            for case let view as UIImageView in views(in: row, limit: 60) { restore(view) }
        }
    }
    @MainActor static func album(in row: UIView) -> Album? {
        for case let label as UILabel in views(in: row, limit: 60) {
            if let text = label.text, let album = albums[key(text)] { return album }
        }
        return nil
    }
    @MainActor static func relabel(_ root: UIView, album: Album, limit: Int) {
        busy = true; defer { busy = false }
        for case let label as UILabel in views(in: root, limit: limit) {
            guard let text = label.text, let replaced = albumSubtitle(for: text, artists: album.subtitle) else { continue }
            label.text = replaced
        }
    }
    /// The row's artwork: its largest roughly square image view.
    @MainActor static func picture(in row: UIView) -> UIImageView? {
        views(in: row, limit: 60).compactMap { $0 as? UIImageView }
            .filter { $0.bounds.width >= 24 && abs($0.bounds.width - $0.bounds.height) < 4 }
            .max { $0.bounds.width < $1.bounds.width }
    }
    @MainActor static func show(_ album: Album, in view: UIImageView) {
        guard let cover = cover(album) else { return }
        if showing.object(forKey: view) == nil { showing.setObject(view.image ?? UIImage(), forKey: view) }
        busy = true; view.image = cover; busy = false
    }
    @MainActor static func restore(_ view: UIImageView) {
        guard let original = showing.object(forKey: view) else { return }
        showing.removeObject(forKey: view)
        busy = true; view.image = original.size == .zero ? nil : original; busy = false
    }
    @MainActor static func cover(_ album: Album) -> UIImage? {
        guard let file = album.coverFile else { return nil }
        if let cached = covers[file] { return cached }
        guard let image = UIImage(contentsOfFile: file.path) else { return nil }
        covers[file] = image
        return image
    }

    /// The list cell a view sits in, or a few levels up when it isn't in one.
    @MainActor static func container(of view: UIView) -> UIView {
        var current = view, levels = 0
        while let parent = current.superview, levels < 8 {
            if current is UICollectionViewCell || current is UITableViewCell { return current }
            current = parent; levels += 1
        }
        var fallback = view
        for _ in 0..<3 { fallback = fallback.superview ?? fallback }
        return fallback
    }
    @MainActor static func views(in root: UIView, limit: Int) -> [UIView] {
        var queue = [root], found: [UIView] = [], index = 0
        while index < queue.count && found.count < limit {
            let view = queue[index]; index += 1
            found.append(view); queue += view.subviews
        }
        return found
    }
}
