import SwiftUI
import UniformTypeIdentifiers

/// Two update paths, each keeping the other: Scout from GitHub (here), Chroma from Chroma's own
/// Update tab. Scout's IPAs are installed through Chroma's Update tab too, which signs them with
/// your certificate and installs over this app, keeping your data.
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
                scoutSection
                if case .ready(let release, let ipa) = updater.state { install(release, ipa) }
                if let notes = notes, !notes.isEmpty {
                    Section { Text(notes).font(.scoutBody).foregroundStyle(Color.scoutGrey).textSelection(.enabled) } header: { ScoutHeader("What's new") }
                }
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
            .navigationTitle("Updates").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
        .preferredColorScheme(.dark).tint(.scoutGreen)
    }

    // MARK: Scout, from GitHub

    private var scoutSection: some View {
        Section {
            HStack(spacing: 8) {
                RowLabel(title: "Scout \(updater.currentVersion)", subtitle: status, symbol: "sparkles", tint: tint)
                if busy { ProgressView().controlSize(.small) }
            }.padding(.vertical, 3).accessibilityElement(children: .combine).accessibilityIdentifier("scout.updates.status")
            if case .working(_, let fraction) = updater.state, fraction > 0 {
                ProgressView(value: fraction).tint(.scoutGreen)
            }
            switch updater.state {
            case .available(let release):
                NavRow(title: "Get Scout \(release.version)", subtitle: "Download it and build the IPA to install.", symbol: "arrow.down.circle", tint: .scoutGreen) {
                    Task { await updater.prepare(release) }
                }.accessibilityIdentifier("scout.updates.get")
            case .working, .checking: EmptyView()
            default:
                NavRow(title: "Check for updates", subtitle: updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" }, symbol: "arrow.clockwise") {
                    Task { await updater.check() }
                }.accessibilityIdentifier("scout.updates.check")
            }
        } header: { ScoutHeader("Scout") } footer: {
            ScoutNote("From github.com/\(ScoutUpdater.repository). An update replaces only Scout; Chroma stays as it is.")
        }
    }

    private func install(_ release: ScoutUpdater.Release, _ ipa: URL) -> some View {
        Section {
            RowLabel(title: ipa.lastPathComponent, subtitle: "Files → On My iPhone → Spotify → Scout IPAs", symbol: "shippingbox", tint: .scoutGreen)
                .padding(.vertical, 3)
            ShareLink(item: ipa) { HStack { RowLabel(title: "Share the IPA", subtitle: "For another signing app.", symbol: "square.and.arrow.up"); Chevron() } }
                .buttonStyle(.plain).padding(.vertical, 3)
        } header: { ScoutHeader("Install Scout \(release.version)") } footer: {
            ScoutNote("Open Chroma's Update tab, tap Add a Spotify IPA, pick this file and install. Chroma signs it with your certificate and installs it over this Spotify, keeping your data and Chroma.")
        }
    }

    // MARK: Chroma, from its Update tab

    private var chromaSection: some View {
        Section {
            RowLabel(title: "Chroma updates in its Update tab", subtitle: "Scout stays in the app Chroma installs.", symbol: "paintpalette")
                .padding(.vertical, 3)
            RowLabel(title: ChromaHook.isAttached ? "Watching Chroma's Add a Spotify IPA" : "Chroma's updater isn't here",
                     subtitle: ChromaHook.isAttached ? "A Spotify IPA you add there gets Scout first." : "Add Scout to a new Spotify IPA below before adding it in Chroma.",
                     symbol: ChromaHook.isAttached ? "checkmark.circle" : "exclamationmark.circle", tint: ChromaHook.isAttached ? .scoutGreen : .white)
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
            if let adding { ProgressView(value: adding).tint(.scoutGreen) }
            if let added {
                RowLabel(title: added.lastPathComponent, subtitle: "Saved in Spotify → Scout IPAs. Add it in Chroma's Update tab.", symbol: "checkmark.circle", tint: .scoutGreen)
                    .padding(.vertical, 3).accessibilityIdentifier("scout.updates.added")
                ShareLink(item: added) { HStack { RowLabel(title: "Share the IPA", symbol: "square.and.arrow.up"); Chevron() } }.buttonStyle(.plain)
            }
            if let addError { RowLabel(title: addError, symbol: "exclamationmark.circle", tint: .scoutRed) }
        } header: { ScoutHeader("New Spotify version") }
    }

    // MARK: State

    private var notes: String? {
        switch updater.state {
        case .available(let release), .ready(let release, _): return release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return nil
        }
    }
    private var busy: Bool {
        switch updater.state { case .checking, .working: return true; default: return false }
    }
    private var status: String {
        switch updater.state {
        case .idle: return updater.lastChecked == nil ? "Not checked yet" : "Tap Check for updates"
        case .checking: return "Checking GitHub…"
        case .upToDate: return "Up to date"
        case .available(let release): return "Scout \(release.version) is out"
        case .working(let what, let fraction): return fraction > 0 ? "\(what)… \(Int(fraction * 100))%" : "\(what)…"
        case .ready(let release, _): return "Scout \(release.version) is ready to install"
        case .failed(let message): return message
        }
    }
    private var tint: Color {
        switch updater.state {
        case .available, .ready: return .scoutGreen
        case .failed: return .scoutRed
        default: return .white
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
