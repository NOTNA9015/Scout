import SwiftUI
import UniformTypeIdentifiers

/// Two update paths, each keeping the other: Scout from GitHub (here), Chroma from Chroma's own
/// Update tab. Scout's IPAs are installed through Chroma's Update tab too, which signs them with
/// your certificate and installs over this app, keeping your data. Laid out like Chroma's update
/// page: the version big in the middle, its status under it, what's new, then one action.
struct UpdatesView: View {
    @ObservedObject var updater: ScoutUpdater
    @State private var picking = false
    @State private var adding: Double?
    @State private var added: URL?
    @State private var addError: String?
    @State private var made: [URL] = []
    @Environment(\.dismiss) private var dismiss
    static let ipaType = UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .data

    var body: some View {
        NavigationStack {
            List {
                Section { hero }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                if case .ready(let release, let ipa) = updater.state { install(release, ipa) }
                if let release = shownRelease, !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { whatsNew(release) }
                chromaSection
                spotifySection
                if !made.isEmpty {
                    Section {
                        Button(role: .destructive) { updater.deleteMadeIPAs(); refresh() } label: {
                            RowLabel(title: "Delete Scout's IPAs", subtitle: "\(made.count) in Spotify → Scout IPAs, \(size(of: made))", symbol: "trash", tint: .scoutRed)
                        }.accessibilityIdentifier("scout.updates.delete")
                    } footer: { ScoutNote("Once Chroma has installed one, it isn't needed. Keep the newest if Chroma's Update tab still points at it.") }
                }
            }
            .scoutList()
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.white).accessibilityLabel("Close")
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [Self.ipaType]) { result in
                switch result {
                case .success(let url): addScout(to: url)
                case .failure(let error): addError = error.localizedDescription
                }
            }
            .onAppear(perform: refresh)
            // Opening Updates checks GitHub (inside Spotify; the test host never asks).
            .task { if updater.state == .idle, Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil { await updater.check() } }
            .onChange(of: updater.state) { refresh() }
        }
        .preferredColorScheme(.dark).tint(.scoutAccent)
    }

    // MARK: Scout, from GitHub

    private var hero: some View {
        VStack(spacing: 10) {
            Text("Scout \(updater.currentVersion)").font(.scoutHero).foregroundStyle(.white)
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small).tint(statusColor) } else { Image(systemName: statusSymbol).symbolRenderingMode(.hierarchical) }
                Text(status).multilineTextAlignment(.center)
            }
            .font(.system(size: 17, weight: .medium)).foregroundStyle(statusColor)
            if case .working(_, let fraction) = updater.state, fraction > 0 {
                ProgressView(value: fraction).tint(.scoutAccent).frame(maxWidth: 240)
            }
            Text("From github.com/\(ScoutUpdater.repository). An update replaces only Scout; Chroma stays as it is.")
                .font(.scoutSubtitle).foregroundStyle(Color.scoutGrey).multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .accessibilityElement(children: .combine).accessibilityIdentifier("scout.updates.status")
    }

    private func whatsNew(_ release: ScoutUpdater.Release) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("What's New in \(release.version)").font(.scoutTitle)
                    Spacer()
                    Link("Release Notes", destination: release.page).font(.system(size: 17)).foregroundStyle(Color.scoutAccent)
                }
                Text(release.notes.trimmingCharacters(in: .whitespacesAndNewlines)).font(.scoutBody).foregroundStyle(Color.scoutGrey).textSelection(.enabled)
            }.padding(.vertical, 8)
        }
    }

    private func install(_ release: ScoutUpdater.Release, _ ipa: URL) -> some View {
        Section {
            RowLabel(title: ipa.lastPathComponent, subtitle: "Files → On My iPhone → Spotify → Scout IPAs", symbol: "shippingbox")
                .padding(.vertical, 3)
            ShareLink(item: ipa) { HStack { RowLabel(title: "Share the IPA", subtitle: "For another signing app.", symbol: "square.and.arrow.up"); Chevron() } }
                .buttonStyle(.plain).padding(.vertical, 3)
        } header: { ScoutHeader("Install Scout \(release.version)") } footer: {
            ScoutNote("Open Chroma's Update tab, tap Add a Spotify IPA, pick this file and install. Chroma signs it with your certificate and installs it over this Spotify, keeping your data and Chroma.")
        }
    }

    /// The one thing to do next, as a glass button at the bottom.
    @ViewBuilder private var actionBar: some View {
        switch updater.state {
        case .checking, .working, .ready: EmptyView()
        default:
            let release: ScoutUpdater.Release? = { if case .available(let release) = updater.state { return release }; return nil }()
            Button {
                Task { if let release { await updater.prepare(release) } else { await updater.check() } }
            } label: {
                Label(release.map { "Get Scout \($0.version)" } ?? "Check for Updates", systemImage: release == nil ? "arrow.clockwise" : "arrow.down")
                    .font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .modifier(ActionStyle(prominent: release != nil))
            .accessibilityIdentifier(release == nil ? "scout.updates.check" : "scout.updates.get")
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .background(LinearGradient(colors: [Color.scoutBackground.opacity(0), Color.scoutBackground], startPoint: .top, endPoint: .center))
        }
    }

    // MARK: Chroma, from its Update tab

    private var chromaSection: some View {
        Section {
            RowLabel(title: "Chroma updates in its Update tab", subtitle: "Scout stays in the app Chroma installs.", symbol: "paintpalette")
                .padding(.vertical, 3)
            RowLabel(title: ChromaHook.isAttached ? "Watching Add a Spotify IPA" : "Chroma's updater isn't here",
                     subtitle: ChromaHook.isAttached ? "A Spotify IPA you add there gets Scout first." : "Add Scout to a new Spotify IPA below before adding it in Chroma.",
                     symbol: ChromaHook.isAttached ? "checkmark.circle" : "exclamationmark.circle")
                .padding(.vertical, 3).accessibilityIdentifier("scout.updates.chroma")
        } header: { ScoutHeader("Chroma") } footer: {
            ScoutNote("When Chroma moves to a new Spotify version it asks for a decrypted Spotify IPA. That IPA has no Scout, so Scout adds itself to it.")
        }
    }

    private var spotifySection: some View {
        Section {
            NavRow(title: "Add Scout to a Spotify IPA", subtitle: "Pick a decrypted Spotify IPA; a copy with Scout is saved.", symbol: "plus.square.on.square") {
                added = nil; addError = nil; picking = true
            }.disabled(adding != nil).accessibilityIdentifier("scout.updates.add")
            if let adding { ProgressView(value: adding).tint(.scoutAccent) }
            if let added {
                RowLabel(title: added.lastPathComponent, subtitle: "Saved in Spotify → Scout IPAs. Add it in Chroma's Update tab.", symbol: "checkmark.circle", tint: .scoutAccent)
                    .padding(.vertical, 3).accessibilityIdentifier("scout.updates.added")
                ShareLink(item: added) { HStack { RowLabel(title: "Share the IPA", symbol: "square.and.arrow.up"); Chevron() } }.buttonStyle(.plain)
            }
            if let addError { RowLabel(title: addError, symbol: "exclamationmark.circle", tint: .scoutRed) }
        } header: { ScoutHeader("New Spotify version") }
    }

    // MARK: State

    private var shownRelease: ScoutUpdater.Release? {
        switch updater.state {
        case .available(let release), .ready(let release, _): return release
        default: return nil
        }
    }
    private var busy: Bool {
        switch updater.state { case .checking, .working: return true; default: return false }
    }
    private var status: String {
        let spotify = updater.spotifyVersion.isEmpty ? "" : " · Spotify \(updater.spotifyVersion)"
        switch updater.state {
        case .idle: return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        case .checking: return "Checking GitHub…"
        case .upToDate: return "Up to date\(spotify)"
        case .available(let release): return "Scout \(release.version) is out"
        case .working(let what, let fraction): return fraction > 0 ? "\(what)… \(Int(fraction * 100))%" : "\(what)…"
        case .ready(let release, _): return "Scout \(release.version) is ready to install"
        case .failed(let message): return message
        }
    }
    private var statusSymbol: String {
        switch updater.state {
        case .upToDate: return "checkmark.seal.fill"
        case .available, .ready: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }
    private var statusColor: Color {
        switch updater.state {
        case .upToDate, .available, .ready: return .scoutAccent
        case .failed: return .scoutRed
        default: return .scoutGrey
        }
    }
    private func addScout(to url: URL) {
        adding = 0; addError = nil
        Task {
            do { added = try await updater.addScout(toIPA: url) { adding = $0 } }
            catch { addError = error.localizedDescription }
            adding = nil; refresh()
        }
    }
    private func refresh() { made = updater.madeIPAs() }
    private func size(of files: [URL]) -> String {
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A page's main action: green prominent glass when it moves you on, plain glass otherwise.
struct ActionStyle: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent).tint(.scoutAccent).foregroundStyle(Color.onScoutAccent).controlSize(.extraLarge)
        } else {
            content.buttonStyle(.glass).foregroundStyle(.white).controlSize(.extraLarge)
        }
    }
}
