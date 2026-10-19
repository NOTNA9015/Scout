import UIKit

/// A short log of the Spotify pages that appeared (class, title, page URI), kept in
/// Files → On My iPhone → Spotify → "Scout pages.txt", so Scout's page detection can be fixed
/// from what Spotify really shows. Nothing leaves the phone.
@MainActor enum PageLog {
    private static var lines: [String] = []
    private static var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scout pages.txt") }

    /// The controller's class and whatever page URI / identifier Spotify gives it.
    static func identity(_ controller: UIViewController) -> String {
        var parts = [NSStringFromClass(type(of: controller))]
        for name in ["spt_pageURI", "pageURI", "spt_pageIdentifier", "pageIdentifier", "URI"] {
            let selector = NSSelectorFromString(name)
            guard controller.responds(to: selector), let value = controller.perform(selector)?.takeUnretainedValue() else { continue }
            if let url = value as? URL { parts.append(url.absoluteString) } else if let text = value as? String { parts.append(text) }
        }
        return parts.joined(separator: " | ")
    }

    static func note(_ controller: UIViewController) {
        guard Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil,
              let view = controller.viewIfLoaded, let window = view.window,
              view.bounds.width >= window.bounds.width * 0.8, !(controller is UINavigationController),
              !(controller is ScoutHostController), !NSStringFromClass(type(of: controller)).hasPrefix("_TtGC7SwiftUI") else { return }
        let title = controller.navigationItem.title ?? controller.title ?? ""
        let parent = controller.parent.map { NSStringFromClass(type(of: $0)) } ?? "-"
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(identity(controller))  title=\"\(title)\"  parent=\(parent)"
        if lines.last == line { return }
        lines.append(line); if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        let text = lines.joined(separator: "\n") + "\n", target = file
        DispatchQueue.global(qos: .utility).async { try? text.write(to: target, atomically: true, encoding: .utf8) }
    }
}
