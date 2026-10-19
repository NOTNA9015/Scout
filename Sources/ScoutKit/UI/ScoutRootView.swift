import SwiftUI

/// The little menu: import a song or an album. Choosing one opens the full flow.
public struct ScoutRootView: View {
    @State private var flow: ScoutFlow?
    @State private var showConverter = false
    @State private var showEditor = false
    @ObservedObject private var downloads = DownloadManager.shared
    let makeFetcher: @MainActor () -> SongFetching
    let catalog: CatalogSearching
    let lyrics: LyricsSearching
    let library: ScoutLibrary
    let listener: AudioListening
    let autoBegin: (@MainActor () async -> [DownloadedSong])?
    var expand: () -> Void
    var close: () -> Void
    public init(fetcher: @escaping @MainActor () -> SongFetching = { ScoutService.shared }, catalog: CatalogSearching = CatalogSearch(),
                lyrics: LyricsSearching = LyricsSearch(), library: ScoutLibrary = .shared, listener: AudioListening = OnDeviceListener(), autoBegin: (@MainActor () async -> [DownloadedSong])? = nil,
                expand: @escaping () -> Void = {}, close: @escaping () -> Void) {
        makeFetcher = fetcher; self.catalog = catalog; self.lyrics = lyrics; self.library = library; self.listener = listener; self.autoBegin = autoBegin
        self.expand = expand; self.close = close
    }
    public var body: some View {
        Group {
            if let flow { FlowContainer(flow: flow, close: { flow.discard(); close() }) }
            else { menu }
        }
        .preferredColorScheme(.dark).tint(.scoutGreen)
        // A download started here keeps running even if the sheet was closed and reopened; pick it
        // back up, and open the detail steps the moment it finishes.
        .task { reattach() }
        .onChange(of: downloads.pendingStamp) { deliver() }
        .sheet(isPresented: $showConverter) { AudioConverterView(library: library) }
        .sheet(isPresented: $showEditor) { LibraryEditorView(library: library) }
    }
    /// Opened mid-download (or with one already finished and unclaimed): rebuild the flow so the
    /// user lands back in the import instead of a fresh menu.
    private func reattach() {
        guard flow == nil, downloads.isRunning || downloads.pending != nil else { return }
        let next = makeFlow(downloads.pending?.mode ?? downloads.runningMode ?? .song)
        next.downloading = true
        expand(); withAnimation { flow = next }
        deliver()
    }
    /// Give a finished download to the waiting flow, once.
    private func deliver() {
        guard let flow, flow.downloading, let pending = downloads.claim() else { return }
        flow.deliver(pending)
    }
    private func makeFlow(_ mode: ScoutFlow.Mode) -> ScoutFlow {
        ScoutFlow(mode: mode, fetcher: makeFetcher(), catalog: catalog, lyrics: lyrics, library: library, listener: listener)
    }
    private var menu: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Scout", systemImage: "sparkle.magnifyingglass").font(.title2.bold())
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.buttonStyle(.glass).accessibilityLabel("Close")
            }
            MenuButton(title: "Import a song", detail: "Find one song, then name it, add artists, a cover and lyrics.", icon: "music.note") { start(.song) }
                .accessibilityIdentifier("scout.menu.song")
            MenuButton(title: "Import an album", detail: "Pick songs from any search, then set them up together.", icon: "square.stack") { start(.album) }
                .accessibilityIdentifier("scout.menu.album")
            MenuButton(title: "File converter", detail: "Convert existing files to Spotify audio. Keep the originals.", icon: "arrow.triangle.2.circlepath") { expand(); showConverter = true }
                .accessibilityIdentifier("scout.menu.converter")
            MenuButton(title: "Edit imports", detail: "Change the names, artists, covers, lyrics or order of songs and albums.", icon: "pencil") { expand(); showEditor = true }
                .accessibilityIdentifier("scout.menu.edit")
            CompileRow(library: library)
            Spacer(minLength: 0)
        }
        .padding(20).background(Color.scoutBackground)
    }
    private func start(_ mode: ScoutFlow.Mode) {
        let next = makeFlow(mode)
        expand()
        withAnimation { flow = next }
        if let autoBegin { Task { let songs = await autoBegin(); next.begin(with: mode == .song ? Array(songs.prefix(1)) : songs) } }
    }
}

/// Compile pending playlists from the menu too (the same as the button on Local Files).
struct CompileRow: View {
    @ObservedObject var library: ScoutLibrary
    @State private var working = false
    @State private var result: String?
    var body: some View {
        if !library.waiting.isEmpty || result != nil {
            VStack(alignment: .leading, spacing: 6) {
                MenuButton(title: working ? "Compiling…" : "Compile pending playlists (\(library.waiting.count))",
                           detail: "Make the albums you imported into Spotify playlists.", icon: working ? "hourglass" : "music.note.list") {
                    guard !working, !library.waiting.isEmpty else { return }
                    working = true; result = nil
                    Task {
                        let outcome = await library.compileWaiting()
                        working = false
                        var lines = outcome.made.map { "Made \($0.name)." }
                        lines += outcome.failed.map { "\($0.name): \($0.lastError ?? "Couldn't make the playlist.")" }
                        result = lines.joined(separator: "\n")
                    }
                }.accessibilityIdentifier("scout.menu.compile")
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scout.menu.compile.result") }
            }
        }
    }
}

struct MenuButton: View {
    var title: String, detail: String, icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 44, height: 44).background(Color.scoutGreen.opacity(0.18), in: .rect(cornerRadius: 12)).foregroundStyle(Color.scoutGreen)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline).foregroundStyle(.white); Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(14).glassEffect(in: .rect(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

struct FlowContainer: View {
    @ObservedObject var flow: ScoutFlow
    var close: () -> Void
    var body: some View {
        NavigationStack(path: $flow.path) {
            FinderView(flow: flow, scout: ScoutEntry.searchService)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
                .navigationDestination(for: ScoutFlow.Step.self) { step in
                    Group {
                        switch step {
                        case .names: NameStep(flow: flow)
                        case .artists: ArtistStep(flow: flow)
                        case .cover: CoverStep(flow: flow)
                        case .lyrics: LyricsStep(flow: flow)
                        case .album: AlbumStep(flow: flow)
                        case .saving: SavingView(flow: flow)
                        case .done: DoneView(flow: flow, close: close)
                        }
                    }
                    .toolbar { if step != .saving && step != .done { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } } }
                }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(flow.current != nil)
        .alert(flow.mode == .song ? "No lyrics found" : "\(flow.missingLyrics) \(flow.missingLyrics == 1 ? "song has" : "songs have") no lyrics",
               isPresented: $flow.askGenerate) {
            Button("Generate them") { flow.answerGenerate(true) }
            Button("No thanks", role: .cancel) { flow.answerGenerate(false) }
        } message: { Text("Scout can write the lyrics from the audio on this iPhone, with each word timed.") }
    }
}
