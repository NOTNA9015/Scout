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
                Section {
                    QuickButton(title: "Quick setup everything",
                                detail: flow.mode == .album ? "Clean names, artists, covers, lyrics and the album, all picked for you, then imported."
                                                            : "Clean name, artists, cover and lyrics, all picked for you, then imported.") { flow.quickSetupEverything() }
                        .accessibilityIdentifier("scout.quick.all")
                }
            }
            Section {
                SearchBox(placeholder: "Search names", text: Suggestions.nameVariants(draft.title).last ?? draft.title, busy: searching) { term in
                    searching = true; Task { await flow.loadMatches(for: draft.id, term: term); searching = false }
                }
                ForEach(Array(flow.nameOptions(draft).enumerated()), id: \.offset) { _, name in
                    OptionRow(title: name, detail: detail(name, draft), selected: draft.title == name,
                              duration: flow.matches[draft.id]?.first(where: { $0.title == name })?.duration ?? TrackTime.valid(draft.song.duration), showsDuration: true) { flow.drafts[index].title = name }
                }
            } header: { ScoutHeader("Suggestions") }
            Section {
                FieldRow(placeholder: "Type a name", text: $flow.drafts[index].title).accessibilityIdentifier("scout.name.custom")
            } header: { ScoutHeader("Your own") }
        }.id("names-\(index)")
    }
    private func detail(_ name: String, _ draft: SongDraft) -> String? {
        guard let match = flow.matches[draft.id]?.first(where: { $0.title == name }) else { return nil }
        return ([Suggestions.joinArtists(match.artists), match.album, match.source].filter { !$0.isEmpty }).joined(separator: " · ")
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
                Section {
                    Text(draft.artistText).font(.scoutTitle).foregroundStyle(Color.scoutAccent).accessibilityIdentifier("scout.artists.current")
                } header: { ScoutHeader("On this song") }
            }
            Section {
                SearchBox(placeholder: "Search artists", text: draft.artists.first ?? "", busy: searching) { term in
                    searching = true
                    Task { let names = await flow.catalog.artists(term); found = merged(found + names); searching = false }
                }
                ForEach(options, id: \.self) { name in
                    OptionRow(title: name, selected: draft.artists.contains(name), multiple: true) {
                        if let at = flow.drafts[index].artists.firstIndex(of: name) { flow.drafts[index].artists.remove(at: at) }
                        else { flow.drafts[index].artists.append(name) }
                    }
                }
            } header: { ScoutHeader("Suggestions") } footer: { ScoutNote("The first artist ticked is the main artist.") }
            Section {
                HStack {
                    TextField("Add an artist", text: $custom).font(.scoutInput).onSubmit(add).autocorrectionDisabled()
                    Button("Add", action: add).font(.scoutTitle).foregroundStyle(Color.scoutAccent).buttonStyle(.borderless)
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { ScoutHeader("Someone else") } footer: { ScoutNote("Separate several with commas.") }
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
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
    var body: some View {
        let draft = flow.drafts[0]
        StepPage(flow: flow, title: "Cover", subtitle: "Pick a cover, search for more, or choose a photo.", nextEnabled: !loading) {
            Section {
                SearchBox(placeholder: "Search covers", text: Flow.coverTerm(draft), busy: searching) { term in
                    searching = true; Task { await flow.loadMatches(for: draft.id, term: term); searching = false }
                }
                CoverGrid(options: flow.coverOptions(draft), selectedID: $selectedID, current: draft.cover, columns: columns) { option in
                    loading = true; Task { if let data = await CoverLoader.data(option) { flow.drafts[0].cover = data }; loading = false }
                }.padding(.vertical, 8)
            } header: { ScoutHeader("Covers") }
            Section {
                PhotosPicker(selection: $photo, matching: .images) { HStack { RowLabel(title: "Choose a photo", symbol: "photo.on.rectangle"); Chevron() } }
                    .buttonStyle(.plain)
                Button { flow.drafts[0].cover = nil; selectedID = "none" } label: {
                    HStack { RowLabel(title: "No cover", symbol: "xmark", tint: .scoutRed); if draft.cover == nil { Image(systemName: "checkmark").foregroundStyle(Color.scoutAccent) } }
                }.buttonStyle(.plain)
            }
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
        if options.isEmpty { ScoutNote("No covers found yet. Search above or choose a photo.") }
        else {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(options) { option in
                    Button { selectedID = option.id; pick(option) } label: {
                        CoverTile(option: option, selected: selectedID == option.id || (selectedID == nil && option.data != nil && option.data == current))
                    }.buttonStyle(.borderless)
                }
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
            Section {
                QuickButton(title: "Quick setup lyrics",
                            detail: flow.mode == .album ? "Use the recommended lyrics for every song and generate them for the rest."
                                                        : "Use the recommended lyrics, or generate them if none match.") { flow.quickSetup() }
                    .accessibilityIdentifier("scout.lyrics.quick")
            }
            Section {
                verdict(recommendation, draft: draft)
                SearchBox(placeholder: "Search lyrics by another name", text: Suggestions.nameVariants(draft.title).last ?? draft.title, busy: loading) { term in
                    Task { await flow.loadLyrics(for: draft.id, title: term) }
                }
                if loading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(options.isEmpty ? "Looking for lyrics…" : "Looking for more…").font(.scoutBody).foregroundStyle(Color.scoutGrey) }
                }
                if let error = flow.lyricsErrors[draft.id] {
                    HStack {
                        RowLabel(title: error, symbol: "wifi.exclamationmark", tint: .scoutRed)
                        Button("Retry") { Task { await flow.loadLyrics(for: draft.id) } }.font(.scoutTitle).foregroundStyle(.white).buttonStyle(.borderless)
                    }
                }
                if flow.lyricsNotFound(draft.id) { RowLabel(title: "No lyrics found online for this song.", symbol: "text.badge.xmark", tint: Color.scoutGrey) }
                ForEach(options) { candidate in card(candidate, draft: draft, recommendation: recommendation) }
            } header: { ScoutHeader(options.isEmpty ? "Found" : "Found · \(options.count)") }
            Section {
                if !options.contains(where: { $0.id == "generated" }) {
                    OptionRow(title: "Generate from the audio", detail: "On this iPhone, with every word timed, using lines from the lyrics found where they were sung.", selected: draft.lyrics == .generate) { flow.choose(.generate, for: draft.id) }
                }
                OptionRow(title: "Paste lyrics", detail: "Plain text or LRC", selected: { if case .text(_, "Pasted") = draft.lyrics { return true }; return false }()) { pasted = ""; pasting = true }
                OptionRow(title: "Import a file", detail: ".lrc or .txt", selected: { if case .text(_, "Imported file") = draft.lyrics { return true }; return false }()) { importing = true }
                OptionRow(title: "No lyrics", selected: draft.lyrics == .none) { flow.choose(.none, for: draft.id) }
            } header: { ScoutHeader("Something else") }
            if case .text(let text, _) = draft.lyrics, !LyricsParser.parse(text).contains(where: { !$0.words.isEmpty }) {
                let lineTimed = LyricsParser.parse(text).contains { $0.time != nil }
                Section {
                    Toggle(isOn: $flow.drafts[index].timeWords) { Text("Add word timing from the audio").font(.scoutTitle) }
                        .tint(.scoutAccent).accessibilityIdentifier("scout.lyrics.timewords")
                } footer: { ScoutNote(lineTimed ? "Keeps these lyrics and their lines; times every word." : "Keeps these lyrics; times every line and word.") }
            }
            if draft.song.duration > 0 || !languages.isEmpty {
                Section {
                    if draft.song.duration > 0 {
                        HStack {
                            RowLabel(title: "Your version", symbol: "waveform")
                            Text(Clock.text(draft.song.duration)).font(.scoutTitle.monospacedDigit()).foregroundStyle(Color.scoutGrey)
                        }
                        .accessibilityElement(children: .ignore).accessibilityLabel("Your version: \(Clock.text(draft.song.duration))")
                        .accessibilityIdentifier("scout.lyrics.length")
                    }
                    if !languages.isEmpty {
                        Picker(selection: Binding(get: { flow.locale }, set: { flow.setLocale($0) })) {
                            ForEach(languages, id: \.identifier) { Text(Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier).tag($0) }
                        } label: { RowLabel(title: "Vocal language", symbol: "globe") }
                        .pickerStyle(.menu).tint(Color.scoutGrey)
                    }
                } header: { ScoutHeader("Your audio") } footer: { ScoutNote("Lengths above are compared with your version; Scout listens in the vocal language.") }
            }
        }
        .id("lyrics-\(index)")
        .task { languages = await LocalLyricTranscriber.supportedLanguages(); if let match = languages.first(where: { $0.language.languageCode == flow.locale.language.languageCode }) { flow.locale = match } }
        // A single song with nothing found and nothing heard asks straight away.
        .onChange(of: loading) { _, now in
            if flow.mode == .song && !now && flow.lyricsNotFound(draft.id) && flow.heard[draft.id] == nil && !draft.lyrics.isChosen { flow.promptForMissing() }
        }
        .sheet(item: $reading) { candidate in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(candidate.source).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey); Spacer(); TrackLength(seconds: candidate.duration) }
                        Text(candidate.lines.map(\.text).joined(separator: "\n")).font(ScoutFont.of(17, bold: true)).lineSpacing(6)
                    }.padding(20)
                }
                .background(Color.scoutBackground)
                .navigationTitle(candidate.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { reading = nil } }
                    ToolbarItem(placement: .confirmationAction) { Button("Use these") { flow.choose(.text(candidate.text, source: candidate.source), for: draft.id); reading = nil } }
                }
            }.preferredColorScheme(.dark).tint(.scoutAccent)
        }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasted).font(.body.monospaced()).scrollContentBackground(.hidden).padding(12)
                    .background(Color.scoutBackground)
                    .navigationTitle("Paste lyrics").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pasting = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Use") { flow.choose(.text(pasted, source: "Pasted"), for: draft.id); pasting = false }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
                    .onAppear { pasted = UIPasteboard.general.string ?? "" }
            }.preferredColorScheme(.dark).tint(.scoutAccent)
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
            HStack(spacing: 14) {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                Text(flow.listening[draft.id] ?? "Waiting to listen to your audio…").font(.scoutBody).foregroundStyle(Color.scoutGrey)
            }
        case .recommended(let best, let score) where best.id == "generated":
            verdictRow("Recommended: pieced together — this version differs from the lyrics online (\(Int((score * 100).rounded()))% of it matched their lines)",
                       symbol: "checkmark.seal.fill", tint: .scoutAccent)
        case .recommended(let best, let score):
            verdictRow("Recommended: \(best.title) — \(Int((score * 100).rounded()))% of its words heard in your audio", symbol: "checkmark.seal.fill", tint: .scoutAccent)
        case .noneMatch:
            verdictRow("None of these match your audio. The lyrics generated from it are at the end.", symbol: "exclamationmark.triangle.fill", tint: .scoutRed)
        case .unavailable:
            HStack {
                RowLabel(title: "Couldn't listen to your audio", subtitle: flow.listenErrors[draft.id], symbol: "ear.trianglebadge.exclamationmark", tint: .scoutRed)
                Button("Retry") { flow.relisten(draft.id) }.font(.scoutTitle).foregroundStyle(.white).buttonStyle(.borderless)
            }
        }
    }
    private func verdictRow(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: symbol, tint: tint, fill: tint.opacity(0.15))
            Text(text).font(.scoutTitle).foregroundStyle(tint).accessibilityIdentifier("scout.lyrics.verdict")
        }
    }

    private func card(_ candidate: LyricCandidate, draft: SongDraft, recommendation: ScoutFlow.Recommendation) -> some View {
        let chosen: Bool = { if case .text(let text, _) = draft.lyrics { return text == candidate.text }; return false }()
        let isBest: Bool = { if case .recommended(let best, _) = recommendation { return best.id == candidate.id }; return false }()
        let score = flow.scores[draft.id]?[candidate.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(candidate.kind).font(ScoutFont.of(10, bold: true)).foregroundStyle(candidate.synced ? Color.scoutAccent : .white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(candidate.synced ? Color.scoutAccent.opacity(0.18) : .white.opacity(0.1), in: .capsule)
                if isBest {
                    Text("Recommended").font(ScoutFont.of(10, bold: true)).foregroundStyle(Color.onScoutAccent)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Color.scoutAccent, in: .capsule)
                }
                Text(candidate.source).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                Spacer(minLength: 4)
                if let d = TrackTime.valid(candidate.duration) {
                    let gap = draft.song.duration > 0 ? d - draft.song.duration : nil
                    // Within 2 s is almost surely this version; over 10 s is likely another one.
                    HStack(spacing: 4) { Text(Clock.text(d)).monospacedDigit(); if let gap { Text(Clock.difference(gap)).monospacedDigit() } }
                        .font(ScoutFont.of(11, bold: true))
                        .foregroundStyle(gap.map { abs($0) <= 2 ? Color.scoutAccent : abs($0) > 10 ? Color.scoutRed : Color.scoutGrey } ?? Color.scoutGrey)
                } else { TrackLength() }
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
                    .foregroundStyle(chosen ? Color.scoutAccent : Color.scoutGrey.opacity(0.5)).accessibilityHidden(true)
            }
            // The card takes the tap; VoiceOver reaches it through the title.
            Text("\(candidate.title) — \(candidate.artist)").font(.scoutTitle).foregroundStyle(chosen ? Color.scoutAccent : .white).lineLimit(1)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            HStack(alignment: .firstTextBaseline) {
                if let score {
                    Text("\(Int((score * 100).rounded()))% of its words heard in your audio").font(ScoutFont.of(11, bold: true))
                        .foregroundStyle(score >= LyricsMatch.threshold ? Color.scoutAccent : Color.scoutRed)
                } else if candidate.id == "generated", let assembly = flow.assemblies[draft.id] {
                    Text(assembly.onlineLines > 0 ? "\(assembly.onlineLines) lines from lyrics online, in the order sung · \(assembly.heardLines) as heard"
                                                  : "Every line as heard in your audio").font(ScoutFont.of(11, bold: true)).foregroundStyle(Color.scoutAccent)
                }
                Spacer(minLength: 8)
                Button("Read all") { reading = candidate }.font(.scoutTitle).foregroundStyle(Color.scoutAccent).buttonStyle(.borderless)
            }
            Text(candidate.preview).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(2)
        }
        .padding(.vertical, 6).contentShape(.rect)
        .onTapGesture { flow.choose(.text(candidate.text, source: candidate.source), for: draft.id) }
        .listRowBackground(chosen ? Color.scoutAccent.opacity(0.12) : Color.scoutCard)
    }
}

// MARK: Album name, artists, cover and order

struct AlbumStep: View {
    @ObservedObject var flow: ScoutFlow
    @State private var coverID: String?
    @State private var photo: PhotosPickerItem?
    @State private var searching = false
    @State private var loading = false
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
    var body: some View {
        StepPage(flow: flow, title: "The album", subtitle: "Name it, pick its cover and set the song order.", nextTitle: "Import",
                 nextEnabled: !flow.albumName.trimmingCharacters(in: .whitespaces).isEmpty && !loading) {
            Section {
                SearchBox(placeholder: "Search albums and covers", text: ([flow.albumName] + flow.albumArtists.prefix(1)).joined(separator: " "), busy: searching) { term in
                    searching = true; Task { await flow.searchAlbums(term); searching = false }
                }
            } footer: { ScoutNote("Finds names, covers, release dates and © lines in the catalogs.") }

            Section {
                ForEach(flow.albumNameOptions(), id: \.self) { name in
                    OptionRow(title: name, selected: flow.albumName == name) { flow.albumName = name }
                }
                FieldRow(placeholder: "Type an album name", text: $flow.albumName).accessibilityIdentifier("scout.album.name")
            } header: { ScoutHeader("Name") }

            Section {
                let names = Array(Set(flow.drafts.flatMap(\.artists) + flow.albumMatches.flatMap(\.artists))).sorted()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(names, id: \.self) { name in
                            Button { if let at = flow.albumArtists.firstIndex(of: name) { flow.albumArtists.remove(at: at) } else { flow.albumArtists.append(name) } } label: {
                                Chip(title: name, icon: nil, selected: flow.albumArtists.contains(name))
                            }.buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 6)
                }.scrollClipDisabled()
            } header: { ScoutHeader("Album artists") } footer: {
                if !flow.albumArtists.isEmpty { ScoutNote(Suggestions.joinArtists(flow.albumArtists), color: .scoutAccent) }
            }

            Section {
                CoverGrid(options: flow.albumCoverOptions(), selectedID: $coverID, current: flow.albumCover, columns: columns) { option in
                    loading = true; Task { if let data = await CoverLoader.data(option) { flow.albumCover = data }; loading = false }
                }.padding(.vertical, 8)
                PhotosPicker(selection: $photo, matching: .images) { HStack { RowLabel(title: "Choose a photo", symbol: "photo.on.rectangle"); Chevron() } }
                    .buttonStyle(.plain)
            } header: { ScoutHeader("Cover") }

            Section {
                ReleaseDatePicker(date: $flow.albumDate, suggestions: flow.albumDateOptions())
            } header: { ScoutHeader("Release date") }

            Section {
                ForEach(Array(flow.drafts.enumerated()), id: \.element.id) { index, draft in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.scoutBody.monospacedDigit()).foregroundStyle(Color.scoutGrey).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(draft.title).font(.scoutTitle)
                            Text(draft.artistText).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
                        }
                        Spacer()
                        TrackLength(seconds: draft.song.duration, file: draft.song.file)
                    }
                }.onMove(perform: flow.move)
            } header: { ScoutHeader("Order") } footer: { ScoutNote("Drag to reorder.") }
        }
        .environment(\.editMode, .constant(.active))
        .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { flow.albumCover = data; coverID = "photo" } } }
        .task { if flow.albumMatches.isEmpty && !flow.albumName.isEmpty { await flow.searchAlbums(([flow.albumName] + flow.albumArtists.prefix(1)).joined(separator: " ")) } }
    }
}

// MARK: Saving / done

struct SavingView: View {
    @ObservedObject var flow: ScoutFlow
    var body: some View {
        let done = flow.drafts.filter { flow.progress[$0.id] == "Saved" }.count
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Importing").font(.scoutHeading)
                    Text("Saving to Spotify's local files").font(.scoutBody).foregroundStyle(Color.scoutGrey)
                    ProgressView(value: Double(done), total: Double(max(flow.drafts.count, 1))).tint(.scoutAccent)
                    Text("\(done) of \(flow.drafts.count) saved").font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).monospacedDigit()
                }.padding(.top, 4)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            Section {
                ForEach(flow.drafts) { draft in
                    let status = flow.progress[draft.id] ?? "Waiting"
                    HStack(spacing: 12) {
                        CoverThumb(data: (flow.mode == .album ? flow.albumCover : nil) ?? draft.cover ?? draft.song.embeddedArtwork ?? draft.song.artwork, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(draft.title).font(.scoutTitle)
                            Text(status).font(.scoutSubtitle).foregroundStyle(status.hasPrefix("Failed") ? Color.scoutRed : Color.scoutGrey)
                        }
                        Spacer()
                        TrackLength(seconds: draft.song.duration, file: draft.song.file)
                        if status == "Saved" { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutAccent) } else { ProgressView().controlSize(.small) }
                    }
                }
            } header: { ScoutHeader("Songs") }
            Section {
                Button(role: .destructive) { flow.cancelSaving() } label: { RowLabel(title: "Stop", symbol: "stop.fill", tint: .scoutRed) }.buttonStyle(.plain)
            }
        }
        .scoutList()
        .navigationTitle("Importing").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden().interactiveDismissDisabled()
    }
}

struct DoneView: View {
    @ObservedObject var flow: ScoutFlow
    @ObservedObject var library: ScoutLibrary = .shared
    var close: () -> Void
    var body: some View {
        let ok = !flow.saved.isEmpty
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: 52))
                        .foregroundStyle(ok ? Color.scoutAccent : Color.scoutRed)
                    Text(ok ? "\(flow.saved.count) \(flow.saved.count == 1 ? "song" : "songs") saved" : "Nothing was saved")
                        .font(.scoutHeading).accessibilityIdentifier("scout.done.summary")
                    Text("They're in Spotify's Local Files (Files → On My iPhone → Spotify → Scout). If they don't appear, turn on Settings → Local Files in Spotify.")
                        .font(.scoutBody).foregroundStyle(Color.scoutGrey).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }.listRowBackground(Color.clear)
            if let id = flow.plan?.id, let plan = library.playlists.first(where: { $0.id == id }) {
                Section { PlaylistStatusRow(plan: plan, working: library.publishing.contains(id), library: library) } header: { ScoutHeader("Playlist") }
            }
            if !flow.saved.isEmpty {
                Section {
                    ForEach(flow.saved) { song in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.title).font(.scoutTitle)
                                Text([Suggestions.joinArtists(song.artists), song.lyricsSource.map { "Lyrics: " + $0 } ?? "No lyrics"].joined(separator: " · "))
                                    .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
                            }
                            Spacer()
                            TrackLength(seconds: song.duration, file: flow.library.fileURL(song))
                        }
                    }
                } header: { ScoutHeader("Songs") }
            }
            if !flow.failures.isEmpty {
                Section { ForEach(flow.failures, id: \.self) { Text($0).font(.scoutSubtitle).foregroundStyle(Color.scoutRed) } } header: { ScoutHeader("Problems") }
            }
        }
        .scoutList()
        .safeAreaInset(edge: .bottom) {
            Button(action: close) { Text("Done").font(ScoutFont.of(15, bold: true)).frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).tint(.scoutAccent).foregroundStyle(Color.onScoutAccent).controlSize(.large)
                .accessibilityIdentifier("scout.done.close")
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                .background(LinearGradient(colors: [Color.scoutBackground.opacity(0), Color.scoutBackground], startPoint: .top, endPoint: .center))
        }
        .navigationTitle("Imported").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden()
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
            HStack(spacing: 12) {
                CoverThumb(data: library.cover(of: plan), size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.name).font(.scoutTitle)
                    Text(status).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).accessibilityIdentifier("scout.playlist.status")
                }
                Spacer()
                if working { ProgressView() } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scoutAccent) }
            }
            if plan.status == .published, let uri = plan.playlistURI {
                Button("Open in Spotify") { SpotifyLinks.open(uri) }.font(.scoutTitle).foregroundStyle(Color.scoutAccent).buttonStyle(.borderless)
            }
        }
    }
    private var status: String {
        if working { return "Making the playlist…" }
        if plan.status == .published { return "In Your Library as a playlist." }
        return "Done. To make the playlist, open Your Library → Local Files and tap Compile pending playlists."
    }
}
