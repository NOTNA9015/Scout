import UIKit
import SwiftUI

/// Two paths in Chroma's Update tab: a Chroma | Scout switch at the top of Chroma's updater.
///
/// Chroma's side is Chroma's page as it is. Scout's side shows Scout's version and its updates
/// from GitHub; getting one builds this Spotify with the new Scout and adds it as Chroma's Spotify
/// IPA by itself: Scout opens Chroma's picker and answers it before Files shows. Chroma's slider
/// then installs it, signed with your certificate, over this app, keeping your data.
///
/// Whatever Chroma installs keeps Scout: the IPA Scout added, this Spotify (Scout is in it), or a
/// Spotify IPA picked in Files, which Scout adds itself to first (ChromaHook). When Chroma asks for
/// a Spotify IPA while a newer Scout is ready, Scout's IPA is picked for it; asking again opens Files.
@objc(ScoutChromaUpdates) @MainActor public final class ChromaUpdates: NSObject {
    static let switchID = "scout.chroma.switch", panelID = "scout.chroma.panel"
    /// What Chroma's bottom keeps: its notices, their button and the install slider.
    static let bottomReserve: CGFloat = 184

    /// Chroma's updater page: SwiftUI's hosting controller of SGUpdater.UpdateView.
    static func isUpdater(_ controller: UIViewController) -> Bool {
        let name = NSStringFromClass(type(of: controller))
        return name.contains("spotifyglass") && name.contains("SGUpdater") && name.contains("UpdateView")
    }

    /// Chroma's updater is in this app (its picker is), so Scout's updates live on Scout's side of
    /// Chroma's Update tab and Scout's own menu leaves them out. Without Chroma, the menu has them.
    static var chromaIsHere: () -> Bool = { NSClassFromString(ChromaHook.pickerClassName) != nil }
    /// Swappable for tests.
    static var updater: () -> ScoutUpdater = { .shared }
    /// The IPA to hand Chroma the next time it asks for a Spotify IPA, instead of showing Files.
    static var pending: URL?
    /// IPAs already handed to Chroma; a ready one is picked for Chroma only once.
    static var handed: Set<URL> = []
    /// The switch on screen, told when Chroma takes an IPA.
    static weak var paths: ChromaPaths?

    // MARK: Answering Chroma's picker

    /// Bootstrap.m, before any view controller is presented. Chroma's Spotify IPA picker is answered
    /// with Scout's IPA, when there is one, and never shown; everything else is presented as usual.
    @objc public static func answer(_ presented: UIViewController) -> Bool {
        guard let picker = presented as? UIDocumentPickerViewController, let delegate = picker.delegate as? NSObject,
              NSStringFromClass(type(of: delegate)) == ChromaHook.pickerClassName,
              let ipa = pending ?? readyIPA() else { return false }
        pending = nil
        handed.insert(ipa)
        // Through ChromaHook like a pick in Files: an IPA that has the newest Scout goes on as it is.
        _ = delegate.perform(ChromaHook.manySelector, with: picker, with: [ipa] as NSArray)
        paths?.handed(ipa)
        return true
    }

    /// An IPA Scout made with a newer Scout than this one, not yet handed to Chroma.
    static func readyIPA() -> URL? {
        guard case .ready(_, let ipa) = updater().state, !handed.contains(ipa), FileManager.default.fileExists(atPath: ipa.path) else { return nil }
        return ipa
    }

    /// Chroma's scrolling page (its version, what's new and settings), hidden while Scout's side
    /// shows; Chroma's close button, notices and install slider are outside it and stay.
    static func chromaContent(in root: UIView) -> UIView? {
        var queue = root.subviews.map { ($0, 0) }
        while !queue.isEmpty {
            let (view, depth) = queue.removeFirst()
            if view.accessibilityIdentifier == panelID || view.accessibilityIdentifier == switchID { continue }
            if view is UIScrollView, view.bounds.width >= root.bounds.width * 0.9, view.bounds.height >= root.bounds.height * 0.6 { return view }
            if depth < 3 { queue += view.subviews.map { ($0, depth + 1) } }
        }
        return nil
    }

    /// Opens Chroma's picker the way a tap on its Spotify row does, through the row's accessibility
    /// action (what VoiceOver uses), then waits until `done` (Scout has answered it) for a moment.
    /// False when the row isn't found.
    ///
    /// SwiftUI lists its views to accessibility only while app accessibility is on (VoiceOver, Voice
    /// Control, Switch Control…), so when it's off Scout turns it on just for this, then off again.
    static func openChromasPicker(in view: UIView, until done: () -> Bool = { true }) async -> Bool {
        let wasOn = AppAccessibility.isOn
        if !wasOn { AppAccessibility.set(true) }
        defer { if !wasOn { AppAccessibility.set(false) } }
        var row = spotifyRow(in: view)
        for _ in 0..<40 where row == nil && !wasOn {
            try? await Task.sleep(for: .milliseconds(50))
            row = spotifyRow(in: view)
        }
        guard let row, row.accessibilityActivate() else { return false }
        // Chroma presents its picker on its next turn; Scout answers it then (answer(_:)).
        for _ in 0..<40 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
        return true
    }

    static func spotifyRow(in view: UIView) -> NSObject? {
        accessibilityElement(in: view) { element in
            let label = element.accessibilityLabel ?? ""
            return element.accessibilityTraits.contains(.button)
                && (label == "Spotify" || label.hasPrefix("Spotify,") || label.hasPrefix("Add a Spotify IPA") || label.hasPrefix("Add Spotify"))
        }
    }

    static func accessibilityElement(in root: NSObject, where match: (NSObject) -> Bool) -> NSObject? {
        var queue: [NSObject] = [root], seen: Set<ObjectIdentifier> = []
        while !queue.isEmpty && seen.count < 4000 {
            let item = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
            if item.isAccessibilityElement, match(item) { return item }
            if let elements = item.accessibilityElements as? [NSObject] { queue += elements }
            let count = item.accessibilityElementCount()
            if count != NSNotFound, count > 0 { queue += (0..<count).compactMap { item.accessibilityElement(at: $0) as? NSObject } }
            if let view = item as? UIView { queue += view.subviews.filter { !$0.isHidden } }
        }
        return nil
    }

    // MARK: The switch

    /// After every view controller appears (ScoutEntry.attach): Chroma's updater gets the switch.
    static func attach(to controller: UIViewController) {
        guard isUpdater(controller), let root = controller.viewIfLoaded, ScoutEntry.find(root, id: switchID) == nil else { return }
        let updater = updater()
        let paths = ChromaPaths(page: controller)
        self.paths = paths

        let content = chromaContent(in: root)
        let toggle = UIHostingController(rootView: ChromaPathSwitch(paths: paths, updater: updater))
        // On Chroma's own backdrop when its page can be hidden, on Scout's otherwise.
        let panel = UIHostingController(rootView: ChromaScoutPanel(paths: paths, updater: updater, opaque: content == nil))
        for (host, id) in [(panel, panelID), (toggle, switchID)] {
            host.view.backgroundColor = .clear
            host.view.accessibilityIdentifier = id
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.overrideUserInterfaceStyle = .dark
            controller.addChild(host)
            root.addSubview(host.view)
            host.didMove(toParent: controller)
        }
        toggle.sizingOptions = .intrinsicContentSize
        panel.view.isHidden = true
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toggle.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toggle.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            toggle.view.heightAnchor.constraint(equalToConstant: 44),
            panel.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 60),
            panel.view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -bottomReserve),
        ])
        paths.show = { [weak panel, weak root, weak content] path in
            guard let panel, let root else { return }
            if path == .scout { panel.view.alpha = 0; panel.view.isHidden = false }
            UIView.animate(withDuration: 0.2, animations: {
                panel.view.alpha = path == .scout ? 1 : 0
                content?.alpha = path == .scout ? 0 : 1
            }) { _ in panel.view.isHidden = path != .scout }
            root.bringSubviewToFront(panel.view)
            if let toggle = ScoutEntry.find(root, id: switchID) { root.bringSubviewToFront(toggle) }
        }
        if case .idle = updater.state { Task { await updater.check() } }
    }
}

/// Which side of Chroma's Update tab is shown, and what Scout's side has done.
@MainActor final class ChromaPaths: ObservableObject {
    enum Path: Hashable { case chroma, scout }
    @Published var path: Path = .chroma { didSet { if path != oldValue { show(path) } } }
    /// The IPA Chroma took from Scout, and a note when Scout couldn't open Chroma's picker.
    @Published var added: URL?
    @Published var note: String?
    weak var page: UIViewController?
    var show: (Path) -> Void = { _ in }
    init(page: UIViewController) { self.page = page }

    func handed(_ ipa: URL) { added = ipa; note = nil }

    /// Builds this Spotify with the release's Scout (if it isn't built yet) and adds it in Chroma.
    func get(with updater: ScoutUpdater) async {
        note = nil; added = nil
        if case .available(let release) = updater.state { await updater.prepare(release) }
        guard case .ready(_, let ipa) = updater.state else { return }
        await add(ipa)
    }

    /// Opens Chroma's picker and answers it with `ipa`; Files never shows. If Chroma's row can't be
    /// opened, the IPA waits: a tap on Spotify on Chroma's side gets it, still without Files.
    func add(_ ipa: URL) async {
        note = nil; added = nil
        ChromaUpdates.pending = ipa
        ChromaUpdates.handed.remove(ipa)
        if let view = page?.viewIfLoaded { _ = await ChromaUpdates.openChromasPicker(in: view) { [weak self] in self?.added != nil } }
        if added == nil { note = "Switch to Chroma and tap Spotify: Scout answers it with this IPA, no Files needed." }
    }
}

/// Chroma | Scout, at the top of Chroma's updater beside its close button.
struct ChromaPathSwitch: View {
    @ObservedObject var paths: ChromaPaths
    @ObservedObject var updater: ScoutUpdater
    var body: some View {
        Picker("Update", selection: $paths.path) {
            Text("Chroma").tag(ChromaPaths.Path.chroma)
            Text(updateWaiting ? "Scout ●" : "Scout").tag(ChromaPaths.Path.scout)
        }
        .pickerStyle(.segmented).frame(width: 210)
        .accessibilityIdentifier("scout.chroma.paths")
    }
    private var updateWaiting: Bool {
        switch updater.state { case .available, .ready: return true; default: return false }
    }
}

/// Scout's side: its version and status big in the middle, what's new, then getting it.
struct ChromaScoutPanel: View {
    @ObservedObject var paths: ChromaPaths
    @ObservedObject var updater: ScoutUpdater
    var opaque: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                if let release, !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { whatsNew(release) }
                actions
                ScoutNote(footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background { if opaque { ScoutBackdrop() } }
        .preferredColorScheme(.dark).tint(.scoutAccent)
    }

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
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine).accessibilityIdentifier("scout.chroma.status")
    }

    private func whatsNew(_ release: ScoutUpdater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What's New").font(.scoutTitle)
                Spacer()
                Link("Release Notes", destination: release.page).font(.system(size: 17)).foregroundStyle(Color.scoutAccent)
            }
            Text(release.notes.trimmingCharacters(in: .whitespacesAndNewlines)).font(.scoutBody).foregroundStyle(Color.scoutGrey)
        }
        .scoutCard(padding: 18)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button { action() } label: {
                HStack(spacing: 8) { RowLabel(title: actionTitle, subtitle: actionSubtitle, symbol: actionSymbol); Chevron() }
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(.rect)
            }
            .buttonStyle(.plain).disabled(busy).accessibilityIdentifier("scout.chroma.get")
            Divider().overlay(Color.scoutHairline).padding(.leading, 60)
            Link(destination: URL(string: "https://github.com/\(ScoutUpdater.repository)/releases")!) {
                HStack(spacing: 8) { RowLabel(title: "All Scout releases", subtitle: "On GitHub", symbol: "square.stack"); Chevron() }
                    .padding(.horizontal, 16).padding(.vertical, 12).contentShape(.rect)
            }.buttonStyle(.plain)
        }
        .scoutCard()
    }

    // MARK: State

    private var release: ScoutUpdater.Release? {
        switch updater.state {
        case .available(let release), .ready(let release, _): return release
        default: return nil
        }
    }
    private var busy: Bool {
        switch updater.state { case .checking, .working: return true; default: return false }
    }
    private func action() {
        if release != nil { Task { await paths.get(with: updater) } } else { Task { await updater.check() } }
    }
    private var actionTitle: String {
        guard let release else { return "Check now" }
        if paths.added != nil { return "Add Scout \(release.version) again" }
        if case .ready = updater.state { return "Add Scout \(release.version) to Chroma" }
        return "Get Scout \(release.version)"
    }
    private var actionSubtitle: String {
        if release == nil { return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Asks GitHub for a newer Scout" }
        return "Builds this Spotify with it and adds it in Chroma"
    }
    private var actionSymbol: String { release == nil ? "arrow.clockwise" : "arrow.down.circle" }
    private var footnote: String {
        if let note = paths.note { return note }
        if paths.added != nil { return "Chroma has this Spotify with Scout \(release?.version ?? "in it") as its Spotify IPA. Slide below to install it: Chroma signs it with your certificate and installs it over this Spotify, keeping your data." }
        return "An update replaces only Scout. Scout adds it in Chroma by itself, then Chroma's slider installs it over this Spotify, keeping your data and Chroma."
    }
    private var status: String {
        if paths.added != nil { return "\(release.map { "Scout \($0.version)" } ?? "Added") in Chroma · slide to install" }
        switch updater.state {
        case .idle: return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        case .checking: return "Checking GitHub…"
        case .upToDate: return "Up to date"
        case .available(let release): return "Scout \(release.version) is out"
        case .working(let what, let fraction): return fraction > 0 ? "\(what)… \(Int(fraction * 100))%" : "\(what)…"
        case .ready(let release, _): return "Scout \(release.version) is ready"
        case .failed(let message): return message
        }
    }
    private var statusSymbol: String {
        if paths.added != nil { return "checkmark.seal.fill" }
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
}

/// App accessibility, the switch VoiceOver, Voice Control and Switch Control turn on, read and set
/// through the accessibility library.
@MainActor enum AppAccessibility {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void
    private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)

    static var isOn: Bool {
        guard let symbol = dlsym(library, "_AXSApplicationAccessibilityEnabled") else { return false }
        return unsafeBitCast(symbol, to: Get.self)()
    }
    static func set(_ on: Bool) {
        guard let symbol = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else { return }
        unsafeBitCast(symbol, to: Set.self)(on)
    }
}
