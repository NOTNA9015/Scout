import SwiftUI

/// The little menu: import a song or an album. Choosing one opens the full flow.
public struct ScoutRootView: View {
    @State private var flow: ScoutFlow?
    @State private var showConverter = false
    @State private var showEditor = false
    @State private var showUpdates = false
    @ObservedObject private var updater = ScoutUpdater.shared
    @ObservedObject private var downloads = DownloadManager.shared
    let makeFetcher: @MainActor () -> SongFetching
    let catalog: CatalogSearching
    let lyrics: LyricsSearching
    @ObservedObject var library: ScoutLibrary
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
        .preferredColorScheme(.dark).tint(.scoutAccent)
        // A download started here keeps running even if the sheet was closed and reopened; pick it
        // back up, and open the detail steps the moment it finishes.
        .task { reattach() }
        .onChange(of: downloads.pendingStamp) { deliver() }
        .sheet(isPresented: $showConverter) { AudioConverterView(library: library) }
        .sheet(isPresented: $showEditor) { LibraryEditorView(library: library) }
        .sheet(isPresented: $showUpdates) { UpdatesView(updater: updater) }
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
        NavigationStack {
            List {
                Section {
                    NavRow(title: "Import a song", subtitle: "One song: name, artists, cover and lyrics.", symbol: "music.note") { start(.song) }
                        .accessibilityIdentifier("scout.menu.song")
                    NavRow(title: "Import an album", subtitle: "Songs from any search, set up together.", symbol: "square.stack") { start(.album) }
                        .accessibilityIdentifier("scout.menu.album")
                } header: { ScoutHeader("Import") }
                Section {
                    NavRow(title: "Edit imports", subtitle: "Names, artists, covers, lyrics and order.", symbol: "pencil",
                           value: library.songs.isEmpty ? nil : "\(library.songs.count)") { expand(); showEditor = true }
                        .accessibilityIdentifier("scout.menu.edit")
                    NavRow(title: "File converter", subtitle: "Spotify-ready copies; originals stay.", symbol: "arrow.triangle.2.circlepath") { expand(); showConverter = true }
                        .accessibilityIdentifier("scout.menu.converter")
                } header: { ScoutHeader("Library") }
                CompileRow(library: library)
                // With Chroma, Scout's updates are in Chroma's Update tab (its Scout side) instead.
                if !ChromaUpdates.chromaIsHere() {
                    Section {
                        NavRow(title: "Updates", subtitle: "Scout from GitHub, Chroma from its Update tab.", symbol: "arrow.down.circle",
                               value: updateValue, tint: updateAvailable ? .scoutAccent : .white) { expand(); showUpdates = true }
                            .accessibilityIdentifier("scout.menu.updates")
                    } header: { ScoutHeader("Scout") }
                }
            }
            .scoutList()
            // Inside Spotify only: the test host never asks GitHub.
            .onAppear { if Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil { updater.checkIfDue() } }
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle("Scout").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { close() } label: { Image(systemName: "xmark") }.tint(.white).accessibilityLabel("Close")
                }
            }
        }
    }
    private var updateAvailable: Bool {
        switch updater.state { case .available, .ready: return true; default: return false }
    }
    private var updateValue: String { updateAvailable ? "Update" : updater.currentVersion }
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
            Section {
                Button {
                    guard !working, !library.waiting.isEmpty else { return }
                    working = true; result = nil
                    Task {
                        let outcome = await library.compileWaiting()
                        working = false
                        var lines = outcome.made.map { "Made \($0.name)." }
                        lines += outcome.failed.map { "\($0.name): \($0.lastError ?? "Couldn't make the playlist.")" }
                        result = lines.joined(separator: "\n")
                    }
                } label: {
                    HStack(spacing: 8) {
                        RowLabel(title: working ? "Compiling…" : "Compile pending playlists (\(library.waiting.count))",
                                 subtitle: "Turn imported albums into Spotify playlists.", symbol: "music.note.list", tint: library.waiting.isEmpty ? .white : .scoutAccent)
                        if working { ProgressView().controlSize(.small) } else { Chevron() }
                    }.padding(.vertical, 3).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("scout.menu.compile")
            } header: { ScoutHeader("Playlists") } footer: {
                if let result { ScoutNote(result).accessibilityIdentifier("scout.menu.compile.result") }
            }
        }
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
    }
}
