import SwiftUI
import PhotosUI

/// Edit what was already imported: a Songs tab and an Albums tab. Changes are written back into
/// the files' tags, so Spotify and spoti.pw read them too.
struct LibraryEditorView: View {
    enum Tab: String, CaseIterable { case songs = "Songs", albums = "Albums" }
    @ObservedObject var library: ScoutLibrary
    @State private var tab: Tab = .songs
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
            .navigationTitle("Edit imports").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { library.forgetMissingFiles() }
        }.preferredColorScheme(.dark).tint(.scoutGreen)
    }

    @ViewBuilder private var songs: some View {
        if library.songs.isEmpty { Text("Songs you import with Scout show up here.").foregroundStyle(.secondary) }
        ForEach(library.songs.sorted { $0.savedAt > $1.savedAt }) { song in
            NavigationLink { SongEditor(library: library, song: song) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                        Text([Suggestions.joinArtists(song.artists), song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    TrackLength(seconds: song.duration, file: library.fileURL(song))
                }
            }.accessibilityIdentifier("scout.editor.song")
        }
    }

    @ViewBuilder private var albums: some View {
        if library.playlists.isEmpty { Text("Albums you import with Scout show up here.").foregroundStyle(.secondary) }
        ForEach(library.playlists.sorted { $0.createdAt > $1.createdAt }) { plan in
            NavigationLink { AlbumEditor(library: library, plan: plan) } label: {
                HStack(spacing: 12) {
                    CoverThumb(data: library.cover(of: plan), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.name)
                        Text("\(Suggestions.joinArtists(plan.artists)) · \(plan.songIDs.count) \(plan.songIDs.count == 1 ? "song" : "songs")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.accessibilityIdentifier("scout.editor.album")
        }
    }
}

struct CoverThumb: View {
    var data: Data?
    var size: CGFloat
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Color.white.opacity(0.06); Image(systemName: "music.note").foregroundStyle(.secondary) } }
        }.frame(width: size, height: size).clipShape(.rect(cornerRadius: size / 8))
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
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle") }
                if replacement != nil { Button("Keep the current cover") { replacement = nil; photo = nil }.font(.caption) }
            }
        }
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
            Section("Song") {
                TextField("Name", text: $title).accessibilityIdentifier("scout.editor.title")
                TextField("Artists, separated by commas", text: $artists).autocorrectionDisabled().accessibilityIdentifier("scout.editor.artists")
                if let plan {
                    LabeledContent("Album", value: plan.name)
                } else {
                    TextField("Album", text: $album)
                    Stepper("Track \(trackNumber)", value: $trackNumber, in: 1...999)
                }
            }
            Section("Cover") {
                if plan != nil { Text("This song uses its album's cover. Change it in the Albums tab.").font(.caption).foregroundStyle(.secondary) }
                else { CoverPicker(current: currentCover, replacement: $newCover) }
            }
            Section {
                TextEditor(text: $lyrics).frame(minHeight: 180).font(.callout.monospaced()).accessibilityIdentifier("scout.editor.lyrics")
            } header: { Text("Lyrics") } footer: { Text("Timed lines like [01:02.30] are kept. Leave empty for none.") }
            if plan?.status == .published {
                Section { Text("Spotify knows this song by its name, artists and album. If you change them, tap Compile pending playlists to add the edited song to the album in Spotify, then remove the old entry there.")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
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
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(library: ScoutLibrary, plan: PlaylistPlan) {
        self.library = library; self.plan = plan
        _name = State(initialValue: plan.name); _artists = State(initialValue: Suggestions.joinArtists(plan.artists))
    }

    var body: some View {
        Form {
            Section("Album") {
                TextField("Album name", text: $name).accessibilityIdentifier("scout.editor.albumname")
                TextField("Artists, separated by commas", text: $artists).autocorrectionDisabled()
            }
            Section("Cover") { CoverPicker(current: library.cover(of: plan), replacement: $newCover) }
            Section {
                ForEach(Array(order.enumerated()), id: \.element.id) { number, song in
                    HStack {
                        Text("\(number + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(song.title)
                        Spacer()
                        TrackLength(seconds: song.duration, file: library.fileURL(song))
                    }
                }.onMove { order.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("Songs") } footer: { Text("Drag to reorder. Edit a song's own name, artists or lyrics in the Songs tab.") }
            if plan.status == .published {
                Section { Text("This album is already in Spotify. Its songs are retagged here; tap Compile pending playlists to add the edited songs to it. Spotify keeps the album's original name and order.")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(plan.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("scout.editor.save") }
            }
        }
        .interactiveDismissDisabled(saving).navigationBarBackButtonHidden(saving)
        .onAppear { if order.isEmpty { order = library.songs(in: plan) } }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                _ = try await library.edit(plan, name: name.trimmingCharacters(in: .whitespacesAndNewlines), artists: Suggestions.splitArtists(artists),
                                           cover: newCover, order: order.map(\.id))
                saving = false; dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}
