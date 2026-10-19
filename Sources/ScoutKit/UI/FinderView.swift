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
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    private var single: Bool { flow.mode == .song }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 20)
                        TextField(single ? "Song, album, era or tracker" : "Search, pick songs, search again", text: $query).submitLabel(.search).focused($searchFocused).onSubmit(search).autocorrectionDisabled()
                            .accessibilityIdentifier("scout.search.query")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search") }
                        Button(action: search) { Image(systemName: "arrow.up").font(.subheadline.bold()).foregroundStyle(.black).frame(width: 32, height: 32).background(Color.scoutGreen, in: .circle) }
                            .disabled((query.trimmingCharacters(in: .whitespaces).isEmpty && ArtistTracker(rawValue: source) == nil) || scout.loading).accessibilityLabel("Search")
                    }.padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
                    Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 48)
                    HStack(spacing: 12) {
                        Image(systemName: "person").foregroundStyle(.secondary).frame(width: 20)
                        TextField("Artist (recommended)", text: $artistQuery).submitLabel(.search).onSubmit(search).autocorrectionDisabled()
                    }.font(.subheadline).padding(.horizontal, 16).frame(height: 44)
                }.glassEffect(in: .rect(cornerRadius: 22))

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

                if flow.downloading || downloads.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(downloads.detail.isEmpty ? "Downloading…" : downloads.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(Int((downloads.fraction * 100).rounded()))%").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Cancel") { downloads.cancel(); flow.downloading = false }.font(.footnote.weight(.semibold)).foregroundStyle(.orange).accessibilityIdentifier("scout.download.cancel")
                        }
                        ProgressView(value: downloads.fraction).tint(.scoutGreen)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.06), in: .rect(cornerRadius: 14))
                    .accessibilityIdentifier("scout.download.progress")
                } else if scout.loading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(scout.importStatus.isEmpty ? "Searching…" : scout.importStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                if let error = scout.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 14))
                }
                if let tracker = scout.tracker {
                    HStack(alignment: .firstTextBaseline) {
                        Link(destination: tracker.url) { Label(tracker.rawValue, systemImage: "arrow.up.right.square") }
                        Spacer()
                        Text("\(scout.tracks.count) versions").foregroundStyle(.secondary)
                    }.font(.footnote)
                }
                if !flow.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) { ForEach(flow.failures, id: \.self) { Text($0).font(.caption) } }.foregroundStyle(.orange)
                }
                if !scout.tracks.isEmpty { trackList }
                else if !scout.collections.isEmpty {
                    HStack(alignment: .firstTextBaseline) { Text("Results").font(.title3.bold()); Spacer(); Text("\(scout.collections.count)").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(scout.collections) { album in
                            Button { collection = album; Task { await scout.open(album) } } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArchiveArt(identifier: album.identifier).aspectRatio(1, contentMode: .fit)
                                    Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                                    Text(album.artist == "Unknown artist" ? "Artist not verified" : album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                } else if searched && !scout.loading && scout.error == nil {
                    ContentUnavailableView.search(text: query)
                } else if !searched {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(single ? "Find the song" : "Find the songs").font(.title3.bold())
                        Text(single ? "Search, pick the version you want, then Download." : "Search as often as you like and tick songs from any result. Your picks stay selected until you press Done.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Try “Frank Ocean tracker”, “Ye tracker” or “Kendrick tracker”, or pick a tracker above to search its songs and eras.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Color.scoutBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(single ? "Import a song" : "Import an album")
        .safeAreaInset(edge: .bottom) { if !flow.basket.isEmpty { bottomBar } }
        .sheet(isPresented: $showBasket) { BasketView(flow: flow) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio], allowsMultipleSelection: !single) { result in useFiles(result) }
        .onDisappear { scout.stopPreview() }
        .onChange(of: query) { scout.filterTracker(query, artist: artistQuery) }
        .onChange(of: artistQuery) { scout.filterTracker(query, artist: artistQuery) }
        .onChange(of: scout.loading) { if !scout.loading { scout.filterTracker(query, artist: artistQuery) } }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { if !single { showBasket = true } } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(single ? flow.basket[0].title : "\(flow.basket.count) selected").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !single { Text("Review").font(.caption).foregroundStyle(Color.scoutGreen) }
                    else {
                        HStack { Text(flow.basket[0].artist).font(.caption).foregroundStyle(.secondary).lineLimit(1); TrackLength(track: flow.basket[0]) }
                    }
                }
            }.buttonStyle(.plain)
            Spacer()
            Button { flow.download() } label: {
                Label(single ? "Download" : "Done", systemImage: single ? "arrow.down.to.line" : "checkmark").padding(.horizontal, 10).padding(.vertical, 4)
            }.buttonStyle(.glassProminent).tint(.scoutGreen).foregroundStyle(.black).disabled(flow.downloading || downloads.isRunning).accessibilityIdentifier("scout.download")
        }.padding(12).glassEffect(in: .capsule).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if scout.tracker == nil {
                    Button { scout.tracks = []; collection = nil; scout.stopPreview() } label: { Chip(title: "Results", icon: "chevron.left") }
                }
                Spacer()
                if !single {
                    let all = scout.tracks.allSatisfy(flow.isSelected)
                    Button(all ? "Deselect all" : "Select all") { for track in scout.tracks where flow.isSelected(track) == all { flow.toggle(track) } }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutGreen)
                }
            }
            if let collection {
                HStack(alignment: .bottom, spacing: 16) {
                    ArchiveArt(identifier: collection.identifier).frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(collection.title).font(.title3.bold()).lineLimit(3)
                        Text(collection.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            LazyVStack(spacing: 4) {
                ForEach(scout.tracks) { track in
                    let selected = flow.isSelected(track)
                    VStack(spacing: 0) {
                      HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? Color.scoutGreen : .white.opacity(0.3)).frame(width: 30, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(scout.tracker == nil ? (track.version ?? track.artist) : [track.album, track.version ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        TrackLength(track: track)
                        Button { scout.preview(track) } label: { Image(systemName: "play.fill").frame(width: 40, height: 44) }.accessibilityLabel("Preview \(track.title)")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected ? Color.scoutGreen.opacity(0.1) : .clear, in: .rect(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                    .onTapGesture { flow.toggle(track) }
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                      if scout.previewTrackID == track.id { InlinePreviewPlayer(scout: scout) }
                    }
                    .onScrollVisibilityChange(threshold: 0.01) { visible in if !visible { scout.stopPreview(matching: track.id) } }
                    .onDisappear { scout.stopPreview(matching: track.id) }
                }
            }
        }
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
                ForEach(flow.basket) { track in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(track.title); Text(track.album).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        TrackLength(track: track)
                    }
                }.onDelete { flow.basket.remove(atOffsets: $0) }.onMove { flow.basket.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("\(flow.basket.count) selected").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct Chip: View {
    let title: String
    let icon: String?
    var trailing = false
    var selected = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon, !trailing { Image(systemName: icon).font(.caption.weight(.semibold)) }
            Text(title).lineLimit(1)
            if let icon, trailing { Image(systemName: icon).font(.caption2.weight(.bold)) }
        }
        .font(.subheadline).foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 14).frame(height: 32)
        .background(selected ? Color.scoutGreen : Color.white.opacity(0.12), in: .capsule)
    }
}

struct ArchiveArt: View {
    let identifier: String
    var body: some View {
        AsyncImage(url: URL(string: "https://archive.org/services/img/")?.appendingPathComponent(identifier)) { image in image.resizable().scaledToFill() }
        placeholder: { ZStack { Color.white.opacity(0.055); Image(systemName: "opticaldisc").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary) } }
            .clipped().clipShape(.rect(cornerRadius: 12))
    }
}
