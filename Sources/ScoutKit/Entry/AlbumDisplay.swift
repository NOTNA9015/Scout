import UIKit
import Combine

/// Shows the playlists Scout made from albums as albums, only in how Spotify displays them.
/// - Rows: a row whose title is a Scout album and whose subtitle says "Playlist • <owner>" reads
///   "Album • <artists>", and its picture is the album's cover.
/// - The playlist's own page: the owner's name becomes the album's artists, "Playlist" becomes
///   "Album • <year>", the description (the artists again) is hidden, and the songs lose their
///   own covers, as on an album page; the header shows the album's cover.
/// The playlist itself is unchanged in Spotify. Driven by the label and image hooks in Bootstrap.m.
@objc(ScoutAlbumDisplay) public final class AlbumDisplay: NSObject {
    struct Album {
        var artists: String           // "Frank Ocean, André 3000"
        var coverFile: URL?
        var playlistURI: String?
        var year: Int?
        var songTitles: Set<String> = []
    }
    /// Scout albums that are playlists in Spotify, by the playlist's name there.
    @MainActor static var albums: [String: Album] = [:]
    /// Every song title on those albums, to find their rows on an album's page.
    @MainActor static var songTitles: Set<String> = []
    /// The names Spotify shows as the playlists' owner ("Playlist • Anton"), learned from rows.
    @MainActor static var ownerNames: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ScoutOwnerNames") ?? [])
    @MainActor private static var covers: [URL: UIImage] = [:]
    @MainActor private static var watching: AnyCancellable?
    /// Image views showing a Scout cover, with the picture Spotify last gave each.
    @MainActor private static let showing = NSMapTable<UIImageView, UIImage>.weakToStrongObjects()
    /// Song rows on an album page whose own cover is hidden, and views hidden on a page.
    @MainActor private static let hiddenRows = NSHashTable<UIView>.weakObjects()
    @MainActor private static let hiddenViews = NSHashTable<UIView>.weakObjects()
    /// Each page's playlist URI, if it is one ("" when not), so it is worked out once.
    @MainActor private static let pageURIs = NSMapTable<UIViewController, NSString>.weakToStrongObjects()
    @MainActor private static var queued = NSHashTable<UIView>.weakObjects()
    @MainActor private static var busy = false

    /// Words Spotify puts before the owner in a playlist's subtitle, lowercased.
    static let playlistWords: Set<String> = ["playlist", "public playlist", "playliste", "spilleliste", "spellista", "soittolista",
                                             "afspeellijst", "lista", "playlista", "lista de reprodução", "lista de reproducción"]
    static let separators = [" • ", " · ", " ∙ "]

    @MainActor public static func start(library: ScoutLibrary) {
        watching = library.$playlists.combineLatest(library.$songs).receive(on: RunLoop.main).sink { plans, songs in
            MainActor.assumeIsolated { index(plans, songs: songs, coverFolder: library.supportFolder.appendingPathComponent("Covers")) }
        }
    }
    @MainActor static func index(_ plans: [PlaylistPlan], songs: [SavedSong] = [], coverFolder: URL) {
        albums = [:]; songTitles = []
        for plan in plans where plan.playlistURI != nil {
            let titles = Set(plan.songIDs.compactMap { id in songs.first { $0.id == id }.map { key($0.title) } })
            let album = Album(artists: Suggestions.joinArtists(plan.artists), coverFile: plan.coverFilename.map { coverFolder.appendingPathComponent($0) },
                              playlistURI: plan.playlistURI, year: Calendar.current.dateComponents([.year], from: plan.createdAt).year, songTitles: titles)
            albums[key(plan.spotifyName ?? plan.name)] = album
            songTitles.formUnion(titles)
        }
        covers = covers.filter { url, _ in albums.values.contains { $0.coverFile == url } }
    }
    static func key(_ text: String) -> String { AlbumKey.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// "Playlist • Anton" → "Album • Frank Ocean"; nil when the text isn't a playlist subtitle.
    static func albumSubtitle(for text: String, artists: String) -> String? {
        guard let (_, separator) = playlistKind(text) else { return nil }
        guard let separator, !artists.isEmpty else { return "Album" }
        return "Album" + separator + artists
    }
    /// The owner in "Playlist • Anton", and the separator used; nil when it isn't a playlist subtitle.
    static func playlistKind(_ text: String) -> (owner: String?, separator: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = separators.first { trimmed.contains($0) }
        let parts = separator.map { trimmed.components(separatedBy: $0) } ?? [trimmed]
        guard playlistWords.contains(parts[0].lowercased()) else { return nil }
        return (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil, separator)
    }

    // MARK: Hooks (Bootstrap.m)

    /// A label's text changed: look at its row (or its page) once it has finished filling in.
    @MainActor @objc public static func labelChanged(_ label: UILabel) {
        guard !busy, !albums.isEmpty, let text = label.text, !text.isEmpty, text.count < 300 else { return }
        let lowered = text.lowercased(), key = key(text)
        let interesting = albums[key] != nil || playlistWords.contains(where: lowered.hasPrefix) || songTitles.contains(key) || ownerNames.contains(text)
        let row = container(of: label)
        // A song row on an album page, reused for something else, needs its cover back.
        guard interesting || (hiddenRows.count > 0 && hiddenRows.contains(row)) else { return }
        if queued.contains(row) { return }
        queued.add(row)
        DispatchQueue.main.async { queued.remove(row); refresh(row); refreshPage(around: label) }
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
    /// A page appeared: if it is a playlist Scout made, make it look like an album page.
    @MainActor static func attach(to page: UIViewController) {
        guard !albums.isEmpty, let root = page.viewIfLoaded, let album = album(of: page) else { return }
        dress(root, album: album, limit: 600, wholePage: true)
        // The header's picture: the biggest roughly square image near the top of the page.
        let images = views(in: root, limit: 600).compactMap { $0 as? UIImageView }.filter {
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
            guard let text = label.text, let kind = playlistKind(text), let replaced = albumSubtitle(for: text, artists: album.artists) else { continue }
            if let owner = kind.owner, !owner.isEmpty, !ownerNames.contains(owner) {
                ownerNames.insert(owner)
                UserDefaults.standard.set(Array(ownerNames), forKey: "ScoutOwnerNames")
            }
            label.text = replaced
        }
    }

    // MARK: An album's own page

    @MainActor static func refreshPage(around view: UIView) {
        let row = container(of: view)
        guard let page = owningPage(of: view), let album = album(of: page) else { unhide(row); return }
        if isCell(row), !hasSong(row, of: album) { unhide(row) }
        dress(row, album: album, limit: 60, wholePage: false)
    }
    /// Album-page treatment for everything under `root`: owner → artists, kind → "Album • year",
    /// no covers on the song rows and, for the whole page, no description repeating the artists.
    @MainActor static func dress(_ root: UIView, album: Album, limit: Int, wholePage: Bool) {
        busy = true; defer { busy = false }
        var rows: [UIView] = [], repeats: [UILabel] = [], ownerShown = false
        for case let label as UILabel in views(in: root, limit: limit) {
            guard let text = label.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !hiddenViews.contains(label) else { continue }
            let row = container(of: label)
            if isCell(row) {
                if album.songTitles.contains(key(text)) { rows.append(row) }
                continue
            }
            if ownerNames.contains(text), !album.artists.isEmpty { label.text = album.artists; ownerShown = true }
            else if let kind = playlistKind(text) {
                label.text = kind.separator == nil ? (album.year.map { "Album • \($0)" } ?? "Album") : albumSubtitle(for: text, artists: album.artists)
            }
            else if text == album.artists { repeats.append(label) }
        }
        // The description repeats the artists now shown in the owner's place.
        if wholePage, ownerShown || repeats.count > 1 {
            for label in (ownerShown ? repeats : Array(repeats.dropFirst())) { label.isHidden = true; hiddenViews.add(label) }
        }
        for row in rows {
            for case let image as UIImageView in views(in: row, limit: 40)
            where image.bounds.width >= 24 && image.bounds.width <= 96 && abs(image.bounds.width - image.bounds.height) < 4 && !image.isHidden {
                image.isHidden = true; hiddenViews.add(image); hiddenRows.add(row)
            }
        }
    }
    static func isCell(_ view: UIView) -> Bool { view is UICollectionViewCell || view is UITableViewCell }
    @MainActor static func hasSong(_ row: UIView, of album: Album) -> Bool {
        views(in: row, limit: 60).contains { ($0 as? UILabel)?.text.map { album.songTitles.contains(key($0)) } ?? false }
    }
    @MainActor static func unhide(_ row: UIView) {
        guard hiddenRows.contains(row) else { return }
        hiddenRows.remove(row)
        for view in views(in: row, limit: 40) where hiddenViews.contains(view) { view.isHidden = false; hiddenViews.remove(view) }
    }
    /// The Scout album a page shows, by the playlist URI in its identity.
    @MainActor static func album(of page: UIViewController) -> Album? {
        let uri: String
        if let known = pageURIs.object(forKey: page) { uri = known as String }
        else {
            let identity = PageLog.identity(page)
            uri = identity.components(separatedBy: CharacterSet(charactersIn: " |?")).first { $0.hasPrefix("spotify:playlist:") } ?? ""
            pageURIs.setObject(uri as NSString, forKey: page)
        }
        guard !uri.isEmpty else { return nil }
        return albums.values.first { $0.playlistURI == uri }
    }
    @MainActor static func owningPage(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return ScoutEntry.pageController(controller) }
            responder = current.next
        }
        return nil
    }

    // MARK: Pictures

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
