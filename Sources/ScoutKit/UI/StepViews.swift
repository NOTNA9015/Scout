import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: Name

struct NameStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var searching = false
    var body: some View {
        let index = min(flow.page, flow.drafts.count - 1)
        let draft = flow.drafts[index]
        StepPage(flow: flow, title: "Song name", subtitle: flow.mode == .album ? draft.song.source?.title : "Pick the name, or type your own.",
                 nextEnabled: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty) {
            if index == 0 {
                QuickButton(title: "Quick setup everything",
                            detail: flow.mode == .album ? "Clean names, artists, covers, lyrics and the album, all picked for you, then imported."
                                                        : "Clean name, artists, cover and lyrics, all picked for you, then imported.") { flow.quickSetupEverything() }
                    .accessibilityIdentifier("scout.quick.all")
            }
            SearchBox(placeholder: "Search names", text: Suggestions.nameVariants(draft.title).last ?? draft.title, busy: searching) { term in
                searching = true; Task { await flow.loadMatches(for: draft.id, term: term); searching = false }
            }
            VStack(spacing: 8) {
                ForEach(Array(flow.nameOptions(draft).enumerated()), id: \.offset) { _, name in
                    OptionRow(title: name, detail: detail(name, draft), selected: draft.title == name,
                              duration: flow.matches[draft.id]?.first(where: { $0.title == name })?.duration ?? TrackTime.valid(draft.song.duration), showsDuration: true) { flow.drafts[index].title = name }
                }
            }
            TextField("Type a name", text: $flow.drafts[index].title).padding(14).background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
                .accessibilityIdentifier("scout.name.custom")
        }.id("names-\(index)")
    }
    private func detail(_ name: String, _ draft: SongDraft) -> String? {
        guard let match = flow.matches[draft.id]?.first(where: { $0.title == name }) else { return nil }
        return ([Suggestions.joinArtists(match.artists), match.album, match.source].filter { !$0.isEmpty }).joined(separator: " · ")
    }
}

/// The green one-tap button for a Quick setup.
struct QuickButton: View {
    var title: String
    var detail: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.black).padding(14)
            .background(Color.scoutGreen, in: .rect(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}

// MARK: Artists

struct ArtistStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var custom = ""
    @State private var found: [String] = []
    @State private var searching = false
    var body: some View {
        let index = min(flow.page, flow.drafts.count - 1)
        let draft = flow.drafts[index]
        let options = merged(flow.artistOptions(draft) + found + draft.artists)
        StepPage(flow: flow, title: "Artists", subtitle: flow.mode == .album ? draft.title : "Tick everyone on the song. The first is the main artist.",
                 nextEnabled: !draft.artists.isEmpty) {
            if !draft.artists.isEmpty {
                Text(draft.artistText).font(.headline).foregroundStyle(Color.scoutGreen).accessibilityIdentifier("scout.artists.current")
            }
            SearchBox(placeholder: "Search artists", text: draft.artists.first ?? "", busy: searching) { term in
                searching = true
                Task { let names = await flow.catalog.artists(term); found = merged(found + names); searching = false }
            }
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { name in
                    OptionRow(title: name, selected: draft.artists.contains(name), multiple: true) {
                        if let at = flow.drafts[index].artists.firstIndex(of: name) { flow.drafts[index].artists.remove(at: at) }
                        else { flow.drafts[index].artists.append(name) }
                    }
                }
            }
            HStack {
                TextField("Add an artist", text: $custom).onSubmit(add).autocorrectionDisabled()
                Button("Add", action: add).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(14).background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
        }.id("artists-\(index)").onChange(of: flow.page) { found = [] }
    }
    private func add() {
        let index = min(flow.page, flow.drafts.count - 1)
        for name in Suggestions.splitArtists(custom) where !flow.drafts[index].artists.contains(name) { flow.drafts[index].artists.append(name) }
        custom = ""
    }
    private func merged(_ names: [String]) -> [String] {
        var seen = Set<String>(); return names.filter { !$0.isEmpty && seen.insert(AlbumKey.normalize($0)).inserted }
    }
}

// MARK: Cover (single song)

struct CoverStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var selectedID: String?
    @State private var photo: PhotosPickerItem?
    @State private var searching = false
    @State private var loading = false
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    var body: some View {
        let draft = flow.drafts[0]
        StepPage(flow: flow, title: "Cover", subtitle: "Pick a cover, search for more, or choose a photo.", nextEnabled: !loading) {
            SearchBox(placeholder: "Search covers", text: Flow.coverTerm(draft), busy: searching) { term in
                searching = true; Task { await flow.loadMatches(for: draft.id, term: term); searching = false }
            }
            CoverGrid(options: flow.coverOptions(draft), selectedID: $selectedID, current: draft.cover, columns: columns) { option in
                loading = true; Task { if let data = await CoverLoader.data(option) { flow.drafts[0].cover = data }; loading = false }
            }
            HStack {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle") }
                Spacer()
                Button("No cover", role: .destructive) { flow.drafts[0].cover = nil; selectedID = "none" }
            }.font(.subheadline)
        }
        .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { flow.drafts[0].cover = data; selectedID = "photo" } } }
    }
}

enum Flow {
    static func coverTerm(_ draft: SongDraft) -> String { ([Suggestions.nameVariants(draft.title).last ?? draft.title] + draft.artists.prefix(1)).joined(separator: " ") }
}

struct CoverGrid: View {
    var options: [CoverOption]
    @Binding var selectedID: String?
    var current: Data?
    var columns: [GridItem]
    var pick: (CoverOption) -> Void
    var body: some View {
        if options.isEmpty { Text("No covers found yet. Search above or choose a photo.").font(.footnote).foregroundStyle(.secondary) }
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(options) { option in
                Button { selectedID = option.id; pick(option) } label: {
                    CoverTile(option: option, selected: selectedID == option.id || (selectedID == nil && option.data != nil && option.data == current))
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: Lyrics

struct LyricsStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var reading: LyricCandidate?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var importing = false
    @State private var languages: [Locale] = []
    var body: some View {
        let index = min(flow.page, flow.drafts.count - 1)
        let draft = flow.drafts[index]
        let options = ordered(flow.lyricOptions[draft.id] ?? [], draft.id)
        let loading = flow.lyricsLoading.contains(draft.id)
        let recommendation = flow.recommendation(draft.id)
        StepPage(flow: flow, title: "Lyrics", subtitle: flow.mode == .album ? draft.title : "Scout listens to your song and recommends the lyrics that match it.",
                 nextTitle: flow.mode == .song ? "Import" : "Next") {
            QuickButton(title: "Quick setup lyrics",
                        detail: flow.mode == .album ? "Use the recommended lyrics for every song and generate them for the rest."
                                                    : "Use the recommended lyrics, or generate them if none match.") { flow.quickSetup() }
                .accessibilityIdentifier("scout.lyrics.quick")
            SearchBox(placeholder: "Search lyrics by another name", text: Suggestions.nameVariants(draft.title).last ?? draft.title, busy: loading) { term in
                Task { await flow.loadLyrics(for: draft.id, title: term) }
            }
            if draft.song.duration > 0 {
                Label("Your version: \(Clock.text(draft.song.duration))", systemImage: "waveform").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("scout.lyrics.length")
            }
            verdict(recommendation, draft: draft)
            if loading { HStack { ProgressView(); Text(options.isEmpty ? "Looking for lyrics…" : "Looking for more…").foregroundStyle(.secondary) } }
            if let error = flow.lyricsErrors[draft.id] {
                HStack {
                    Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { Task { await flow.loadLyrics(for: draft.id) } }.font(.subheadline.weight(.semibold))
                }.padding(12).background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12))
            }
            if flow.lyricsNotFound(draft.id) { Label("No lyrics found online for this song.", systemImage: "text.badge.xmark").foregroundStyle(.secondary) }
            VStack(spacing: 8) {
                ForEach(options) { candidate in card(candidate, draft: draft, recommendation: recommendation) }
            }
            VStack(spacing: 8) {
                if !options.contains(where: { $0.id == "generated" }) {
                    OptionRow(title: "Generate from the audio", detail: "On this iPhone, with every word timed, using lines from the lyrics found where they were sung.", selected: draft.lyrics == .generate) { flow.choose(.generate, for: draft.id) }
                }
                OptionRow(title: "Paste lyrics", detail: "Plain text or LRC", selected: { if case .text(_, "Pasted") = draft.lyrics { return true }; return false }()) { pasted = ""; pasting = true }
                OptionRow(title: "Import a file", detail: ".lrc or .txt", selected: { if case .text(_, "Imported file") = draft.lyrics { return true }; return false }()) { importing = true }
                OptionRow(title: "No lyrics", selected: draft.lyrics == .none) { flow.choose(.none, for: draft.id) }
            }
            if case .text(let text, _) = draft.lyrics, !LyricsParser.parse(text).contains(where: { !$0.words.isEmpty }) {
                let lineTimed = LyricsParser.parse(text).contains { $0.time != nil }
                Toggle(isOn: $flow.drafts[index].timeWords) {
                    VStack(alignment: .leading) {
                        Text("Add word timing from the audio")
                        Text(lineTimed ? "Keeps these lyrics and their lines; times every word." : "Keeps these lyrics; times every line and word.").font(.caption).foregroundStyle(.secondary)
                    }
                }.tint(.scoutGreen).accessibilityIdentifier("scout.lyrics.timewords")
            }
            if !languages.isEmpty {
                Picker("Vocal language", selection: Binding(get: { flow.locale }, set: { flow.setLocale($0) })) {
                    ForEach(languages, id: \.identifier) { Text(Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier).tag($0) }
                }.pickerStyle(.menu)
            }
        }
        .id("lyrics-\(index)")
        .task { languages = await LocalLyricTranscriber.supportedLanguages(); if let match = languages.first(where: { $0.language.languageCode == flow.locale.language.languageCode }) { flow.locale = match } }
        // A single song with nothing found and nothing heard asks straight away.
        .onChange(of: loading) { _, now in
            if flow.mode == .song && !now && flow.lyricsNotFound(draft.id) && flow.heard[draft.id] == nil && !draft.lyrics.isChosen { flow.promptForMissing() }
        }
        .sheet(item: $reading) { candidate in
            NavigationStack { ScrollView { VStack(alignment: .leading) { TrackLength(seconds: candidate.duration); Text(candidate.lines.map(\.text).joined(separator: "\n")) }.padding() }.navigationTitle(candidate.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Use these") { flow.choose(.text(candidate.text, source: candidate.source), for: draft.id); reading = nil } } } }
        }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasted).font(.body.monospaced()).padding(8)
                    .navigationTitle("Paste lyrics").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pasting = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Use") { flow.choose(.text(pasted, source: "Pasted"), for: draft.id); pasting = false }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
                    .onAppear { pasted = UIPasteboard.general.string ?? "" }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            guard let url = try? result.get() else { return }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count < 1_000_000 { flow.choose(.text(text, source: "Imported file"), for: draft.id) }
        }
    }

    /// The recommendation first, then the rest as found, the transcript last.
    private func ordered(_ options: [LyricCandidate], _ id: UUID) -> [LyricCandidate] {
        var rest = options.filter { $0.id != "generated" }
        let generated = options.filter { $0.id == "generated" }
        if case .recommended(let best, _) = flow.recommendation(id) {
            if best.id == "generated" { return generated + rest }
            if let at = rest.firstIndex(of: best) { rest.insert(rest.remove(at: at), at: 0) }
        }
        return rest + generated
    }

    @ViewBuilder private func verdict(_ recommendation: ScoutFlow.Recommendation, draft: SongDraft) -> some View {
        switch recommendation {
        case .waiting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(flow.listening[draft.id] ?? "Waiting to listen to your audio…").font(.footnote).foregroundStyle(.secondary)
            }
        case .recommended(let best, let score) where best.id == "generated":
            Label("Recommended: pieced together — this version differs from the lyrics online (\(Int((score * 100).rounded()))% of it matched their lines)", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color.scoutGreen).accessibilityIdentifier("scout.lyrics.verdict")
        case .recommended(let best, let score):
            Label("Recommended: \(best.title) — \(Int((score * 100).rounded()))% of its words heard in your audio", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color.scoutGreen).accessibilityIdentifier("scout.lyrics.verdict")
        case .noneMatch:
            Label("None of these match your audio. The lyrics generated from it are at the end.", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold)).foregroundStyle(.orange).accessibilityIdentifier("scout.lyrics.verdict")
        case .unavailable:
            HStack {
                Label("Couldn't listen to your audio: \(flow.listenErrors[draft.id] ?? "")", systemImage: "ear.trianglebadge.exclamationmark").font(.footnote).foregroundStyle(.orange)
                Spacer()
                Button("Retry") { flow.relisten(draft.id) }.font(.subheadline.weight(.semibold))
            }
        }
    }

    private func card(_ candidate: LyricCandidate, draft: SongDraft, recommendation: ScoutFlow.Recommendation) -> some View {
        let chosen: Bool = { if case .text(let text, _) = draft.lyrics { return text == candidate.text }; return false }()
        let isBest: Bool = { if case .recommended(let best, _) = recommendation { return best.id == candidate.id }; return false }()
        let score = flow.scores[draft.id]?[candidate.id]
        return Button { flow.choose(.text(candidate.text, source: candidate.source), for: draft.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(candidate.kind).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(candidate.synced ? Color.scoutGreen.opacity(0.25) : .white.opacity(0.1), in: .capsule)
                    if isBest { Text("Recommended").font(.caption2.weight(.bold)).foregroundStyle(.black).padding(.horizontal, 7).padding(.vertical, 3).background(Color.scoutGreen, in: .capsule) }
                    Text(candidate.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let d = TrackTime.valid(candidate.duration) {
                        let gap = draft.song.duration > 0 ? d - draft.song.duration : nil
                        // Within 2 s is almost surely this version; over 10 s is likely another one.
                        HStack(spacing: 4) { Text(Clock.text(d)).monospacedDigit(); if let gap { Text(Clock.difference(gap)).monospacedDigit() } }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(gap.map { abs($0) <= 2 ? Color.scoutGreen : abs($0) > 10 ? .orange : .secondary } ?? .secondary)
                    } else { TrackLength() }
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? Color.scoutGreen : .white.opacity(0.35))
                }
                Text("\(candidate.title) — \(candidate.artist)").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let score {
                    Text("\(Int((score * 100).rounded()))% of its words heard in your audio").font(.caption.weight(.medium))
                        .foregroundStyle(score >= LyricsMatch.threshold ? Color.scoutGreen : .orange)
                } else if candidate.id == "generated", let assembly = flow.assemblies[draft.id] {
                    Text(assembly.onlineLines > 0 ? "\(assembly.onlineLines) lines from lyrics online, in the order sung · \(assembly.heardLines) as heard"
                                                  : "Every line as heard in your audio").font(.caption.weight(.medium)).foregroundStyle(Color.scoutGreen)
                }
                Text(candidate.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Read all") { reading = candidate }.font(.caption.weight(.semibold)).foregroundStyle(Color.scoutGreen)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Color.scoutGreen.opacity(0.12) : .white.opacity(0.05), in: .rect(cornerRadius: 14))
            .overlay { if isBest { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.scoutGreen.opacity(0.6), lineWidth: 1.5) } }
        }.buttonStyle(.plain)
    }
}

// MARK: Album name, artists, cover and order

struct AlbumStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var coverID: String?
    @State private var photo: PhotosPickerItem?
    @State private var searching = false
    @State private var loading = false
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    var body: some View {
        StepPage(flow: flow, title: "The album", subtitle: "Name it, pick its cover and set the song order.", nextTitle: "Import",
                 nextEnabled: !flow.albumName.trimmingCharacters(in: .whitespaces).isEmpty && !loading) {
            SearchBox(placeholder: "Search albums and covers", text: ([flow.albumName] + flow.albumArtists.prefix(1)).joined(separator: " "), busy: searching) { term in
                searching = true; Task { await flow.searchAlbums(term); searching = false }
            }
            Text("Name").font(.headline)
            VStack(spacing: 8) {
                ForEach(flow.albumNameOptions(), id: \.self) { name in
                    OptionRow(title: name, selected: flow.albumName == name) { flow.albumName = name }
                }
            }
            TextField("Type an album name", text: $flow.albumName).padding(14).background(.white.opacity(0.05), in: .rect(cornerRadius: 14)).accessibilityIdentifier("scout.album.name")

            Text("Album artists").font(.headline)
            let names = Array(Set(flow.drafts.flatMap(\.artists) + flow.albumMatches.flatMap(\.artists))).sorted()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(names, id: \.self) { name in
                        Button { if let at = flow.albumArtists.firstIndex(of: name) { flow.albumArtists.remove(at: at) } else { flow.albumArtists.append(name) } } label: {
                            Chip(title: name, icon: nil, selected: flow.albumArtists.contains(name))
                        }
                    }
                }
            }.scrollClipDisabled()

            Text("Cover").font(.headline)
            CoverGrid(options: flow.albumCoverOptions(), selectedID: $coverID, current: flow.albumCover, columns: columns) { option in
                loading = true; Task { if let data = await CoverLoader.data(option) { flow.albumCover = data }; loading = false }
            }
            PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle") }.font(.subheadline)

            Text("Order").font(.headline)
            List {
                ForEach(Array(flow.drafts.enumerated()), id: \.element.id) { index, draft in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading) { Text(draft.title); Text(draft.artistText).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        TrackLength(seconds: draft.song.duration, file: draft.song.file)
                    }
                        .listRowBackground(Color.white.opacity(0.05))
                }.onMove(perform: flow.move)
            }
            .environment(\.editMode, .constant(.active)).scrollDisabled(true).scrollContentBackground(.hidden)
            .frame(height: CGFloat(flow.drafts.count) * 64 + 20)
        }
        .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { flow.albumCover = data; coverID = "photo" } } }
        .task { if flow.albumMatches.isEmpty && !flow.albumName.isEmpty { await flow.searchAlbums(([flow.albumName] + flow.albumArtists.prefix(1)).joined(separator: " ")) } }
    }
}

// MARK: Saving / done

struct SavingView: View {
    @ObservedObject var flow: ScoutFlow
    var body: some View {
        List {
            Section { Text("Saving to Spotify's local files").font(.headline) }
            ForEach(flow.drafts) { draft in
                HStack {
                    VStack(alignment: .leading) { Text(draft.title); Text(flow.progress[draft.id] ?? "Waiting").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    TrackLength(seconds: draft.song.duration, file: draft.song.file)
                    if flow.progress[draft.id] == "Saved" { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutGreen) } else { ProgressView() }
                }
            }
            Section { Button("Stop", role: .destructive) { flow.cancelSaving() } }
        }
        .navigationTitle("Importing").navigationBarBackButtonHidden().interactiveDismissDisabled()
    }
}

struct DoneView: View {
    @ObservedObject var flow: ScoutFlow
    @ObservedObject var library: ScoutLibrary = .shared
    var close: () -> Void
    var body: some View {
        List {
            Section {
                Label(flow.saved.isEmpty ? "Nothing was saved" : "\(flow.saved.count) \(flow.saved.count == 1 ? "song" : "songs") saved", systemImage: flow.saved.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(flow.saved.isEmpty ? .orange : Color.scoutGreen).accessibilityIdentifier("scout.done.summary")
                Text("They're in Spotify's Local Files (Files → On My iPhone → Spotify → Scout). If they don't appear, turn on Settings → Local Files in Spotify.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let id = flow.plan?.id, let plan = library.playlists.first(where: { $0.id == id }) {
                Section("Playlist") { PlaylistStatusRow(plan: plan, working: library.publishing.contains(id), library: library) }
            }
            if !flow.saved.isEmpty {
                Section("Songs") {
                    ForEach(flow.saved) { song in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(song.title)
                                Text([Suggestions.joinArtists(song.artists), song.lyricsSource.map { "Lyrics: " + $0 } ?? "No lyrics"].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TrackLength(seconds: song.duration, file: flow.library.fileURL(song))
                        }
                    }
                }
            }
            if !flow.failures.isEmpty { Section("Problems") { ForEach(flow.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } } }
            Section { Button("Done", action: close).frame(maxWidth: .infinity).accessibilityIdentifier("scout.done.close") }
        }
        .navigationTitle("Imported").navigationBarBackButtonHidden()
    }
}

enum Clock {
    static func text(_ seconds: Double) -> String { TrackTime.text(seconds) }
    static func difference(_ gap: Double) -> String {
        let s = Int(gap.rounded())
        if s == 0 { return "same" }
        return (s > 0 ? "+" : "−") + (abs(s) >= 60 ? text(Double(abs(s))) : "\(abs(s))s")
    }
}

struct PlaylistStatusRow: View {
    var plan: PlaylistPlan
    var working: Bool
    var library: ScoutLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.name).font(.headline)
                Spacer()
                if working { ProgressView() } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutGreen) }
            }
            Text(status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("scout.playlist.status")
            if plan.status == .published, let uri = plan.playlistURI {
                Button("Open in Spotify") { SpotifyLinks.open(uri) }.font(.subheadline.weight(.semibold))
            }
        }
    }
    private var status: String {
        if working { return "Making the playlist…" }
        if plan.status == .published { return "In Your Library as a playlist." }
        return "Done. To make the playlist, open Your Library → Local Files and tap Compile pending playlists."
    }
}
