import UIKit
import ObjectiveC

/// Keeps Scout in the app when Chroma's Update tab installs a Spotify IPA you add (Chroma asks for
/// one whenever it moves to a new Spotify version). Chroma's updater picks the IPA with a document
/// picker; Scout answers that picker first and hands Chroma a copy of the IPA with Scout in it.
/// Chroma's other updates need nothing: its patcher keeps the frameworks it finds, Scout included.
///
/// Only Spotify IPAs without this (or a newer) Scout are touched; anything else picked there (the
/// certificate, its profile, a zip) goes to Chroma untouched. If Chroma renames its updater, the
/// hook finds nothing and "Add Scout to a Spotify IPA" in Scout's Updates page does the same by hand.
@MainActor enum ChromaHook {
    nonisolated static let pickerClassName = "_TtCO12spotifyglass9SGUpdater14PickerDelegate"
    static let manySelector = NSSelectorFromString("documentPicker:didPickDocumentsAtURLs:")
    static let oneSelector = NSSelectorFromString("documentPicker:didPickDocumentAtURL:")
    static let cancelSelector = NSSelectorFromString("documentPickerWasCancelled:")

    /// The classes hooked so far.
    static private(set) var attached: Set<String> = []
    static var isAttached: Bool { attached.contains(pickerClassName) }
    /// Swappable for tests.
    static var updater: () -> ScoutUpdater = { .shared }

    @discardableResult
    static func attach(to className: String = pickerClassName) -> Bool {
        if attached.contains(className) { return true }
        guard let cls = NSClassFromString(className) else { return false }
        var hooked = false
        if let method = class_getInstanceMethod(cls, manySelector) {
            typealias Many = @convention(c) (AnyObject, Selector, AnyObject, NSArray) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Many.self)
            let selector = manySelector
            let block: @convention(block) (AnyObject, AnyObject, NSArray) -> Void = { delegate, picker, urls in
                let list = urls.compactMap { $0 as? URL }
                onMain {
                    withScout(list, then: { original(delegate, selector, picker, $0 as NSArray) },
                              cancel: { cancel(delegate, picker) })
                }
            }
            install(imp_implementationWithBlock(block), for: manySelector, in: cls, like: method)
            hooked = true
        }
        if let method = class_getInstanceMethod(cls, oneSelector) {
            typealias One = @convention(c) (AnyObject, Selector, AnyObject, NSURL) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: One.self)
            let selector = oneSelector
            let block: @convention(block) (AnyObject, AnyObject, NSURL) -> Void = { delegate, picker, url in
                onMain {
                    withScout([url as URL], then: { original(delegate, selector, picker, ($0.first ?? url as URL) as NSURL) },
                              cancel: { cancel(delegate, picker) })
                }
            }
            install(imp_implementationWithBlock(block), for: oneSelector, in: cls, like: method)
            hooked = true
        }
        if hooked { attached.insert(className) }
        return hooked
    }

    /// Hands `then` the picked files, with Scout added to the Spotify IPAs that need it.
    static func withScout(_ urls: [URL], then: @escaping ([URL]) -> Void, cancel: @escaping () -> Void) {
        let updater = updater()
        let version = ScoutInjector.version(ofFramework: updater.newestFramework()) ?? "0"
        let needing = urls.indices.filter { index in
            let url = urls[index]
            guard url.pathExtension.lowercased() == "ipa" else { return false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let app = try? ScoutInjector.inspect(ipa: url) else { return false }
            return app.isSpotify && !app.encrypted && ScoutInjector.needsScout(app, version: version)
        }
        // Nothing to do: Chroma gets the files at once, exactly as picked.
        guard !needing.isEmpty else { then(urls); return }

        let alert = UIAlertController(title: "Adding Scout", message: progressText(0), preferredStyle: .alert)
        present(alert)
        Task { @MainActor in
            var result = urls, failure: String?
            for index in needing {
                do {
                    result[index] = try await updater.addScout(toIPA: urls[index]) { fraction in alert.message = progressText(fraction) }
                } catch { failure = error.localizedDescription; break }
            }
            // Never shown (no window yet): go straight on, as dismissing it would never finish.
            let dismiss: (@escaping () -> Void) -> Void = { next in
                if alert.presentingViewController != nil { alert.dismiss(animated: true, completion: next) } else { next() }
            }
            dismiss {
                guard let failure else { then(result); return }
                let ask = UIAlertController(title: "Scout couldn't add itself",
                                            message: "\(failure)\n\nChroma can still install this IPA, but Scout won't be in the app it makes. You can add Scout to the IPA in Scout → Updates and pick that file instead.",
                                            preferredStyle: .alert)
                ask.addAction(UIAlertAction(title: "Continue Without Scout", style: .default) { _ in then(urls) })
                ask.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancel() })
                // No window to ask in: Chroma gets the file as picked rather than waiting forever.
                if !present(ask) { then(urls) }
            }
        }
    }

    static func progressText(_ fraction: Double) -> String {
        "So Chroma's update keeps Scout, Scout is adding itself to this Spotify IPA. Your file isn't changed.\n\n\(Int((fraction * 100).rounded()))%"
    }

    // MARK: Helpers

    private static func install(_ replacement: IMP, for selector: Selector, in cls: AnyClass, like method: Method) {
        // Replace it on the class itself, never on a superclass that others share.
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(class_getInstanceMethod(cls, selector)!, replacement)
        }
    }
    private static func cancel(_ delegate: AnyObject, _ picker: AnyObject) {
        guard delegate.responds(to: cancelSelector) else { return }
        _ = delegate.perform(cancelSelector, with: picker)
    }
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.async { body() } }
    }
    @discardableResult
    private static func present(_ controller: UIViewController) -> Bool {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(controller, animated: true)
        return true
    }
}
