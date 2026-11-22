import SwiftUI
import UniformTypeIdentifiers

struct FinderView: View {
    @ObservedObject var flow: ScoutFlow
    @ObservedObject var scout: ScoutService
    @ObservedObject private var downloads = DownloadManager.shared
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var artistQuery = ""
    private var source: String { scout.selectedSource }
    @State private var searched = false
    @State private var collection: ScoutCollection?
    @State private var showBasket = false
    @State private var picking = false
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private var single: Bool { flow.mode == .song }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchCard
                filters
                status
                if !scout.tracks.isEmpty { trackList }
                else if !scout.collections.isEmpty { collectionGrid }
                else if searched && !scout.loading && scout.error == nil { ContentUnavailableView.search(text: query) }
                else if !searched { welcome }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
        }
        .background(Color.scoutBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(single ? "Import a song" : "Import an album").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if !flow.basket.isEmpty { bottomBar } }
        .sheet(isPresented: $showBasket) { BasketView(flow: flow) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio], allowsMultipleSelection: !single) { result in useFiles(result) }
        .onDisappear { scout.stopPreview() }
        .onChange(of: query) { scout.filterTracker(query, artist: artistQuery) }
        .onChange(of: artistQuery) { scout.filterTracker(query, artist: artistQuery) }
        .onChange(of: scout.loading) { if !scout.loading { scout.filterTracker(query, artist: artistQuery) } }
    }

    // MARK: Search

    private var searchCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.scoutGrey).frame(width: 22)
                TextField(single ? "Song, album, era or tracker" : "Search, pick songs, search again", text: $query).font(.scoutInput)
                    .submitLabel(.search).focused($searchFocused).onSubmit(search).autocorrectionDisabled()
                    .accessibilityIdentifier("scout.search.query")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutGrey) }.accessibilityLabel("Clear search") }
                Button(action: search) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.black).frame(width: 32, height: 32).background(Color.scoutGreen, in: .circle)
                }
                .disabled((query.trimmingCharacters(in: .whitespaces).isEmpty && ArtistTracker(rawValue: source) == nil) || scout.loading).accessibilityLabel("Search")
            }.padding(.leading, 12).padding(.trailing, 8).frame(height: 50)
            Rectangle().fill(Color.scoutHairline).frame(height: 0.5).padding(.leading, 44)
            HStack(spacing: 10) {
                Image(systemName: "person").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.scoutGrey).frame(width: 22)
                TextField("Artist (recommended)", text: $artistQuery).font(.scoutBody).submitLabel(.search).onSubmit(search).autocorrectionDisabled()
            }.padding(.horizontal, 12).frame(height: 42)
        }.scoutCard()
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Internet Archive") { chooseSource("Internet Archive") }
                    ForEach(ArtistTracker.allCases, id: \.rawValue) { tracker in Button(tracker.rawValue) { chooseSource(tracker.rawValue) } }
                    ForEach(scout.customSources, id: \.self) { address in Button(URL(string: address)?.host ?? address) { chooseSource(address) } }
                } label: { Chip(title: ArtistTracker(rawValue: source)?.rawValue ?? (source == "Internet Archive" ? source : URL(string: source)?.host ?? "Source"), icon: "chevron.down", trailing: true) }
                Button { scout.showUncertainMatches.toggle() } label: { Chip(title: "Uncertain matches", icon: nil, selected: scout.showUncertainMatches) }
                Button { picking = true } label: { Chip(title: "Use a file", icon: "folder") }.accessibilityIdentifier("scout.files")
            }
        }.scrollClipDisabled()
    }

    @ViewBuilder private var status: some View {
        if flow.downloading || downloads.isRunning {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SymbolTile(symbol: "arrow.down", tint: .black, fill: .scoutGreen)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Downloading").font(.scoutTitle)
                        Text(downloads.detail.isEmpty ? "Downloading…" : downloads.detail).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                    }
                    Spacer()
                    Text(downloads.percentText).font(.scoutTitle.monospacedDigit()).foregroundStyle(Color.scoutGrey)
                    Button("Cancel") { downloads.cancel(); flow.downloading = false }.font(.scoutTitle).foregroundStyle(Color.scoutRed).accessibilityIdentifier("scout.download.cancel")
                }
                ProgressView(value: downloads.fraction).tint(.scoutGreen)
                if downloads.started { Text(downloads.bytesText).font(.scoutSubtitle.monospacedDigit()).foregroundStyle(Color.scoutGrey) }
            }
            .scoutCard(padding: 12)
            .accessibilityIdentifier("scout.download.progress")
        } else if scout.loading {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(scout.importStatus.isEmpty ? "Searching…" : scout.importStatus).font(.scoutBody).foregroundStyle(Color.scoutGrey) }
        }
        if let tracker = scout.tracker, scout.tracks.isEmpty { trackerLink(tracker) }
        if let error = scout.error {
            RowLabel(title: error, symbol: "exclamationmark.circle", tint: .scoutRed).scoutCard(padding: 12)
        }
        if !flow.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) { ForEach(flow.failures, id: \.self) { Text($0).font(.scoutSubtitle) } }
                .foregroundStyle(Color.scoutRed).scoutCard(padding: 12)
        }
    }

    /// The tracker's own page.
    private func trackerLink(_ tracker: ArtistTracker) -> some View {
        Link(destination: tracker.url) { Label(tracker.rawValue, systemImage: "arrow.up.right.square") }
            .font(.scoutTitle).foregroundStyle(Color.scoutGreen)
    }

    // MARK: Results

    private var collectionGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Results").font(ScoutFont.of(20, bold: true))
                Spacer()
                Text("\(scout.collections.count)").font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(scout.collections) { album in
                    Button { collection = album; Task { await scout.open(album) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArchiveArt(identifier: album.identifier).aspectRatio(1, contentMode: .fit)
                            Text(album.title).font(.scoutTitle).foregroundStyle(.white).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                            Text(album.artist == "Unknown artist" ? "Artist not verified" : album.artist).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if scout.tracker == nil {
                    Button { scout.tracks = []; collection = nil; scout.stopPreview() } label: { Chip(title: "Results", icon: "chevron.left") }
                } else if let tracker = scout.tracker { trackerLink(tracker) }
                Spacer()
                if scout.tracker != nil { Text("\(scout.tracks.count) versions").font(.scoutSubtitle).foregroundStyle(Color.scoutGrey) }
                if !single {
                    let all = scout.tracks.allSatisfy(flow.isSelected)
                    Button(all ? "Deselect all" : "Select all") { for track in scout.tracks where flow.isSelected(track) == all { flow.toggle(track) } }
                        .font(.scoutTitle).foregroundStyle(Color.scoutGreen)
                }
            }
            if let collection {
                HStack(alignment: .bottom, spacing: 16) {
                    ArchiveArt(identifier: collection.identifier).frame(width: 120, height: 120).shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(collection.title).font(ScoutFont.of(20, bold: true)).lineLimit(3)
                        Text(collection.artist).font(.scoutBody).foregroundStyle(Color.scoutGrey).lineLimit(1)
                    }
                }.padding(.bottom, 4)
            }
            LazyVStack(spacing: 2) {
                ForEach(scout.tracks) { track in
                    let selected = flow.isSelected(track)
                    let previewing = scout.previewTrackID == track.id
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Button { scout.preview(track) } label: {
                                Image(systemName: previewing ? "waveform" : "play.fill").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(previewing ? Color.scoutGreen : .white)
                                    .frame(width: 44, height: 44).background(Color.white.opacity(0.08), in: .rect(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel("Preview \(track.title)")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.scoutTitle).foregroundStyle(selected ? Color.scoutGreen : .white).lineLimit(2)
                                Text(scout.tracker == nil ? (track.version ?? track.artist) : [track.album, track.version ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            TrackLength(track: track)
                            Image(systemName: selected ? "checkmark.circle.fill" : single ? "circle" : "plus.circle").font(.system(size: 22))
                                .foregroundStyle(selected ? Color.scoutGreen : Color.scoutGrey.opacity(0.6)).frame(width: 30, height: 44)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                        .onTapGesture { flow.toggle(track) }
                        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                        if previewing { InlinePreviewPlayer(scout: scout) }
                    }
                    .onScrollVisibilityChange(threshold: 0.01) { visible in if !visible { scout.stopPreview(matching: track.id) } }
                    .onDisappear { scout.stopPreview(matching: track.id) }
                }
            }
        }
    }

    /// Before the first search: what to type, and the artist trackers one tap away.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(single ? "Find the song" : "Find the songs").font(.scoutHeading)
                Text(single ? "Search, pick the version you want, then Download." : "Search as often as you like and tick songs from any result. Your picks stay selected until you press Done.")
                    .font(.scoutBody).foregroundStyle(Color.scoutGrey)
            }
            VStack(alignment: .leading, spacing: 8) {
                ScoutHeader("Artist trackers").padding(.leading, 16)
                VStack(spacing: 0) {
                    ForEach(Array(ArtistTracker.allCases.enumerated()), id: \.element.rawValue) { index, tracker in
                        if index > 0 { Rectangle().fill(Color.scoutHairline).frame(height: 0.5).padding(.leading, 58) }
                        NavRow(title: tracker.rawValue, subtitle: "Released and unreleased songs, eras and versions", symbol: "music.mic") { chooseSource(tracker.rawValue) }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }.scoutCard()
                ScoutNote("Or type “Frank Ocean tracker”, “Ye tracker” or “Kendrick tracker”, with a song, era, version or quality.").padding(.horizontal, 16)
            }
        }.padding(.top, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { if !single { showBasket = true } } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(single ? flow.basket[0].title : "\(flow.basket.count) selected").font(.scoutTitle).lineLimit(1)
                    if !single { Text("Review").font(.scoutSubtitle).foregroundStyle(Color.scoutGreen) }
                    else {
                        HStack { Text(flow.basket[0].artist).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).lineLimit(1); TrackLength(track: flow.basket[0]) }
                    }
                }.padding(.leading, 8)
            }.buttonStyle(.plain)
            Spacer()
            Button { flow.download() } label: {
                Label(single ? "Download" : "Done", systemImage: single ? "arrow.down.to.line" : "checkmark").font(ScoutFont.of(15, bold: true))
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }.buttonStyle(.glassProminent).tint(.scoutGreen).foregroundStyle(.black).disabled(flow.downloading || downloads.isRunning).accessibilityIdentifier("scout.download")
        }.padding(10).glassEffect(in: .capsule).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func search() {
        searchFocused = false; searched = true; collection = nil; scout.stopPreview()
        let query = query, artist = artistQuery, source = source
        Task { await scout.search(query, artist: artist, source: source) }
    }
    private func chooseSource(_ next: String) {
        if query.lowercased().contains("tracker"), let request = TrackerSearch.resolve(query, artist: artistQuery, source: source) {
            query = request.terms.joined(separator: " ")
        }
        scout.selectSource(next)
        collection = nil
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ArtistTracker(rawValue: next) != nil { search() }
        else { searched = false }
    }
    private func useFiles(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get(), !urls.isEmpty else { return }
        Task {
            var songs: [DownloadedSong] = []
            try? FileManager.default.createDirectory(at: DownloadedSong.stagingRoot, withIntermediateDirectories: true)
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let folder = DownloadedSong.stagingRoot
                guard let copy = try? await Task.detached(priority: .userInitiated, operation: {
                    let copy = try AudioCompatibility.normalizedCopy(url, into: folder)
                    do { _ = try AudioCompatibility.inspect(copy); return copy }
                    catch { try? FileManager.default.removeItem(at: copy); throw error }
                }).value else { flow.failures.append("\(url.lastPathComponent): This file has no readable audio."); continue }
                var song = await DownloadedSong.make(file: copy, source: nil, artwork: nil)
                if song.taggedTitle == nil { song.taggedTitle = url.deletingPathExtension().lastPathComponent }
                songs.append(song)
            }
            flow.begin(with: songs)
        }
    }
}

/// Picks across searches, with removal.
struct BasketView: View {
    @ObservedObject var flow: ScoutFlow
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(flow.basket) { track in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.scoutTitle)
                                Text(track.album).font(.scoutSubtitle).foregroundStyle(Color.scoutGrey)
                            }
                            Spacer()
                            TrackLength(track: track)
                        }
                    }.onDelete { flow.basket.remove(atOffsets: $0) }.onMove { flow.basket.move(fromOffsets: $0, toOffset: $1) }
                } footer: { ScoutNote("Drag to change the order; tap − to remove a song.") }
            }
            .scoutList()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("\(flow.basket.count) selected").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }.presentationDetents([.medium, .large]).preferredColorScheme(.dark).tint(.scoutGreen)
    }
}

/// Spotify's filter chip: grey, green with black text when on.
struct Chip: View {
    let title: String
    let icon: String?
    var trailing = false
    var selected = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon, !trailing { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(title).lineLimit(1)
            if let icon, trailing { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
        }
        .font(.scoutBody).foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 14).frame(height: 32)
        .background(selected ? Color.scoutGreen : Color.white.opacity(0.12), in: .capsule)
    }
}

struct ArchiveArt: View {
    let identifier: String
    var body: some View {
        AsyncImage(url: URL(string: "https://archive.org/services/img/")?.appendingPathComponent(identifier)) { image in image.resizable().scaledToFill() }
        placeholder: { ZStack { Color.white.opacity(0.06); Image(systemName: "opticaldisc").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Color.scoutGrey) } }
            .clipped().clipShape(.rect(cornerRadius: 6))
    }
}
