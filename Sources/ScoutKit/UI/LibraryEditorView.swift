import SwiftUI
import PhotosUI

/// Edit what was already imported: a Songs tab and an Albums tab. Changes are written back into
/// the files' tags, so Spotify and spoti.pw read them too.
struct LibraryEditorView: View {
    enum Tab: String, CaseIterable { case songs = "Songs", albums = "Albums" }
    @ObservedObject var library: ScoutLibrary
    @State private var tab: Tab = .songs
    @State private var songToDelete: SavedSong?
    @State private var albumToDelete: PlaylistPlan?
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).accessibilityIdentifier("scout.editor.tabs")
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                switch tab {
                case .songs: songs
                case .albums: albums
                }
            }
            .scoutList()
            .navigationTitle("Edit imports").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { library.forgetMissingFiles() }
            .task { await library.removeDuplicates() }
            .deleteSong($songToDelete, library: library) { notice = $0 }
            .deleteAlbum($albumToDelete, library: library) { notice = $0 }
            .alert("Not removed from Spotify", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(notice ?? "") }
        }.preferredColorScheme(.dark).tint(.scoutGreen)
    }

    @ViewBuilder private var songs: some View {
        Section {
            if library.songs.isEmpty { ScoutNote("Songs you import with Scout show up here.") }
            ForEach(library.songs.sorted { $0.savedAt > $1.savedAt }) { song in
                NavigationLink { SongEditor(library: library, song: song) } label: {
                    HStack(spacing: 12) {
                        SongThumb(library: library, song: song)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).font(.scoutTitle)
                            Text([Suggestions.joinArtists(song.artists), song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                        }
                        Spacer()
                        TrackLength(seconds: song.duration, file: library.fileURL(song))
                    }
                }.accessibilityIdentifier("scout.editor.song")
                .swipeActions { Button("Delete", role: .destructive) { songToDelete = song } }
            }
        } header: { if !library.songs.isEmpty { ScoutHeader("\(library.songs.count) \(library.songs.count == 1 ? "song" : "songs")") } }
    }

    @ViewBuilder private var albums: some View {
        Section {
            if library.playlists.isEmpty { ScoutNote("Albums you import with Scout show up here.") }
            ForEach(library.playlists.sorted { $0.createdAt > $1.createdAt }) { plan in
                NavigationLink { AlbumEditor(library: library, plan: plan) } label: {
                    HStack(spacing: 12) {
                        CoverThumb(data: library.cover(of: plan), size: 48)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plan.name).font(.scoutTitle)
                            Text((["Album", Suggestions.joinArtists(plan.artists)] + [plan.releaseDate.map { String($0.formatted(.dateTime.year())) }].compactMap { $0 }
                                  + ["\(plan.songIDs.count) \(plan.songIDs.count == 1 ? "song" : "songs")"]).filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                        }
                    }
                }.accessibilityIdentifier("scout.editor.album")
                .swipeActions { Button("Delete", role: .destructive) { albumToDelete = plan } }
            }
        } header: { if !library.playlists.isEmpty { ScoutHeader("\(library.playlists.count) \(library.playlists.count == 1 ? "album" : "albums")") } }
    }
}

struct CoverThumb: View {
    var data: Data?
    var size: CGFloat
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").foregroundStyle(Color.scoutGrey) } }
        }.frame(width: size, height: size).clipShape(.rect(cornerRadius: max(4, size / 12)))
    }
}

/// A saved song's cover, read from its file when the row shows.
struct SongThumb: View {
    var library: ScoutLibrary
    var song: SavedSong
    @State private var data: Data?
    var body: some View {
        CoverThumb(data: library.album(of: song).flatMap { library.cover(of: $0) } ?? data, size: 40)
            .task(id: song.id) { if library.album(of: song) == nil { data = await library.cover(of: song) } }
    }
}

/// The current cover and a photo to replace it; a nil replacement keeps the current one.
struct CoverPicker: View {
    var current: Data?
    @Binding var replacement: Data?
    @State private var photo: PhotosPickerItem?
    var body: some View {
        HStack(spacing: 16) {
            CoverThumb(data: replacement ?? current, size: 96)
            VStack(alignment: .leading, spacing: 10) {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle").font(.scoutTitle) }
                    .buttonStyle(.borderless)
                if replacement != nil { Button("Keep the current cover") { replacement = nil; photo = nil }.font(.scoutSubtitle).buttonStyle(.borderless) }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { replacement = data } } }
    }
}

struct SongEditor: View {
    @ObservedObject var library: ScoutLibrary
    let song: SavedSong
    @State private var title: String
    @State private var artists: String
    @State private var album: String
    @State private var trackNumber: Int
    @State private var lyrics: String
    @State private var currentCover: Data?
    @State private var newCover: Data?
    @State private var saving = false
    @State private var error: String?
    @State private var deleting: SavedSong?
    @Environment(\.dismiss) private var dismiss

    init(library: ScoutLibrary, song: SavedSong) {
        self.library = library; self.song = song
        _title = State(initialValue: song.title); _artists = State(initialValue: Suggestions.joinArtists(song.artists))
        _album = State(initialValue: song.album); _trackNumber = State(initialValue: song.trackNumber)
        _lyrics = State(initialValue: song.lyrics ?? "")
    }
    private var plan: PlaylistPlan? { library.album(of: song) }

    var body: some View {
        Form {
            Section {
                if plan != nil {
                    HStack(spacing: 12) {
                        CoverThumb(data: plan.flatMap { library.cover(of: $0) }, size: 64)
                        ScoutNote("This song uses its album's cover. Change it in the Albums tab.")
                    }.padding(.vertical, 4)
                } else { CoverPicker(current: currentCover, replacement: $newCover) }
            } header: { ScoutHeader("Cover") }
            Section {
                TextField("Name", text: $title).font(.scoutInput).accessibilityIdentifier("scout.editor.title")
                TextField("Artists, separated by commas", text: $artists).font(.scoutInput).autocorrectionDisabled().accessibilityIdentifier("scout.editor.artists")
                if let plan {
                    LabeledContent { Text(plan.name).font(.scoutBody).foregroundStyle(Color.scoutGrey) } label: { Text("Album").font(.scoutTitle) }
                } else {
                    TextField("Album", text: $album).font(.scoutInput)
                    Stepper(value: $trackNumber, in: 1...999) { Text("Track \(trackNumber)").font(.scoutTitle) }
                }
            } header: { ScoutHeader("Song") }
            Section {
                TextEditor(text: $lyrics).frame(minHeight: 180).font(.callout.monospaced()).accessibilityIdentifier("scout.editor.lyrics")
            } header: { ScoutHeader("Lyrics") } footer: { ScoutNote("Timed lines like [01:02.30] are kept. Leave empty for none.") }
            if plan?.status == .published {
                Section { ScoutNote("Spotify knows this song by its name, artists and album. If you change them, tap Compile pending playlists to add the edited song to the album in Spotify, then remove the old entry there.") }
            }
            if let error { Section { RowLabel(title: error, symbol: "exclamationmark.circle", tint: .scoutRed) } }
            Section {
                Button(role: .destructive) { deleting = song } label: { RowLabel(title: "Delete song", symbol: "trash", tint: .scoutRed) }
                    .disabled(saving).accessibilityIdentifier("scout.editor.delete")
            }
        }
        .scoutList()
        .deleteSong($deleting, library: library) { note in if let note { error = note } else { dismiss() } }
        .navigationTitle(song.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("scout.editor.save") }
            }
        }
        .interactiveDismissDisabled(saving).navigationBarBackButtonHidden(saving)
        .task { if plan == nil { currentCover = await library.cover(of: song) } }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                _ = try await library.edit(song, title: title.trimmingCharacters(in: .whitespacesAndNewlines), artists: Suggestions.splitArtists(artists),
                                           album: plan?.name ?? album.trimmingCharacters(in: .whitespacesAndNewlines),
                                           trackNumber: plan == nil ? trackNumber : song.trackNumber, lyrics: lyrics,
                                           cover: plan == nil ? newCover : nil)
                saving = false; dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

struct AlbumEditor: View {
    @ObservedObject var library: ScoutLibrary
    let plan: PlaylistPlan
    @State private var name: String
    @State private var artists: String
    @State private var order: [SavedSong] = []
    @State private var newCover: Data?
    @State private var releaseDate: Date?
    @State private var saving = false
    @State private var error: String?
    @State private var deleting: PlaylistPlan?
    @State private var loaded = false
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    init(library: ScoutLibrary, plan: PlaylistPlan) {
        self.library = library; self.plan = plan
        _name = State(initialValue: plan.name); _artists = State(initialValue: Suggestions.joinArtists(plan.artists))
        _releaseDate = State(initialValue: plan.releaseDate)
    }

    var body: some View {
        Form {
            Section { CoverPicker(current: library.cover(of: plan), replacement: $newCover) } header: { ScoutHeader("Cover") }
            Section {
                TextField("Album name", text: $name).font(.scoutInput).accessibilityIdentifier("scout.editor.albumname")
                TextField("Artists, separated by commas", text: $artists).font(.scoutInput).autocorrectionDisabled()
            } header: { ScoutHeader("Album") }
            Section { ReleaseDatePicker(date: $releaseDate) } header: { ScoutHeader("Release date") }
            Section {
                ForEach(Array(order.enumerated()), id: \.element.id) { number, song in
                    HStack(spacing: 12) {
                        Text("\(number + 1)").font(.scoutBody.monospacedDigit()).foregroundStyle(Color.scoutGrey).frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).font(.scoutTitle)
                            Text(Suggestions.joinArtists(song.artists)).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                        }
                        Spacer()
                        TrackLength(seconds: song.duration, file: library.fileURL(song))
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { order.remove(atOffsets: $0) }
                Button { adding = true } label: { RowLabel(title: "Add songs", symbol: "plus", tint: .scoutGreen) }
                    .accessibilityIdentifier("scout.editor.addsongs")
            } header: { ScoutHeader("Songs") } footer: {
                ScoutNote("Drag to reorder. Tap − to take a song off the album; it stays in Scout as a single song. Edit a song's own name, artists or lyrics in the Songs tab.")
            }
            if plan.status == .published {
                Section { ScoutNote("This album is already in Spotify. Songs taken off it leave its playlist; for songs added or retagged, tap Compile pending playlists. Spotify keeps the album's original name and order.") }
            }
            if let error { Section { RowLabel(title: error, symbol: "exclamationmark.circle", tint: .scoutRed) } }
            Section {
                Button(role: .destructive) { deleting = plan } label: { RowLabel(title: "Delete album", symbol: "trash", tint: .scoutRed) }
                    .disabled(saving).accessibilityIdentifier("scout.editor.delete")
            }
        }
        .scoutList()
        .deleteAlbum($deleting, library: library) { note in if let note { error = note } else { dismiss() } }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(plan.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || order.isEmpty).accessibilityIdentifier("scout.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(saving).navigationBarBackButtonHidden(saving)
        .onAppear { if !loaded { order = library.songs(in: plan); loaded = true } }
        .sheet(isPresented: $adding) { SongChooser(library: library, album: plan, excluding: Set(order.map(\.id))) { order += $0 } }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                _ = try await library.edit(plan, name: name.trimmingCharacters(in: .whitespacesAndNewlines), artists: Suggestions.splitArtists(artists),
                                           cover: newCover, releaseDate: releaseDate, order: order.map(\.id))
                saving = false; dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

/// Confirm, then delete. `done` gets what couldn't be done in Spotify, or nil.
extension View {
    func deleteSong(_ song: Binding<SavedSong?>, library: ScoutLibrary, done: @escaping (String?) -> Void) -> some View {
        confirmationDialog("Delete \(song.wrappedValue?.title ?? "this song")?", isPresented: Binding(get: { song.wrappedValue != nil }, set: { if !$0 { song.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: song.wrappedValue) { target in
            Button("Delete song", role: .destructive) { Task { done(await library.delete(target)) } }
        } message: { target in
            Text(library.album(of: target)?.playlistURI != nil ? "The file is deleted, and the song is taken out of its album in Spotify." : "The file is deleted from Spotify → Scout.")
        }
    }
    func deleteAlbum(_ plan: Binding<PlaylistPlan?>, library: ScoutLibrary, done: @escaping (String?) -> Void) -> some View {
        confirmationDialog("Delete \(plan.wrappedValue?.name ?? "this album")?", isPresented: Binding(get: { plan.wrappedValue != nil }, set: { if !$0 { plan.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: plan.wrappedValue) { target in
            Button("Delete album and its songs", role: .destructive) { Task { done(await library.delete(target, withSongs: true)) } }
            Button("Delete album, keep the songs") { Task { done(await library.delete(target, withSongs: false)) } }
        } message: { target in
            Text(target.playlistURI != nil ? "Its playlist is removed from Spotify too." : "It hasn't been made in Spotify yet.")
        }
    }
}

/// Picks songs from Scout to add to an album; songs on another album say which.
struct SongChooser: View {
    @ObservedObject var library: ScoutLibrary
    let album: PlaylistPlan
    let excluding: Set<UUID>
    var add: ([SavedSong]) -> Void
    @State private var chosen: [UUID] = []
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var candidates: [SavedSong] {
        let term = AlbumKey.normalize(search)
        return library.songs.filter { !excluding.contains($0.id) }
            .filter { term.isEmpty || AlbumKey.normalize($0.title + " " + Suggestions.joinArtists($0.artists)).contains(term) }
            .sorted { $0.savedAt > $1.savedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty { ScoutNote(library.songs.count <= excluding.count ? "Every song in Scout is already on this album." : "No songs match.") }
                    ForEach(candidates) { song in
                        let other = library.album(of: song).flatMap { $0.id == album.id ? nil : $0 }
                        OptionRow(title: song.title, detail: [Suggestions.joinArtists(song.artists), other.map { "on \($0.name), moves here" }].compactMap { $0 }.joined(separator: " · "),
                                  selected: chosen.contains(song.id), multiple: true) {
                            if let at = chosen.firstIndex(of: song.id) { chosen.remove(at: at) } else { chosen.append(song.id) }
                        }
                        .accessibilityIdentifier("scout.chooser.song")
                    }
                }
            }
            .scoutList()
            .searchable(text: $search, prompt: "Search your songs")
            .navigationTitle("Add songs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.isEmpty ? "Add" : "Add \(chosen.count)") {
                        add(chosen.compactMap { id in library.songs.first { $0.id == id } }); dismiss()
                    }.disabled(chosen.isEmpty).accessibilityIdentifier("scout.chooser.add")
                }
            }
        }.preferredColorScheme(.dark).tint(.scoutGreen)
    }
}
