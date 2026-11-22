import UIKit
import SwiftUI

/// A capsule in Chroma's accent, floating over the bottom of a Spotify page, kept just above the mini player and
/// tab bar as they come and go: the Scout button on Your Library, Compile pending playlists on
/// Local Files.
@MainActor enum FloatingPill {
    enum Placement { case center, trailing }

    static func make(id: String, title: String, symbol: String, placement: Placement, in root: UIView) -> UIButton {
        let button = UIButton(configuration: .prominentGlass())
        button.accessibilityIdentifier = id
        button.configuration?.cornerStyle = .capsule
        button.tintColor = UIColor(Color.scoutAccent)
        button.configuration?.baseForegroundColor = UIColor(Color.onScoutAccent)
        button.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        button.configuration?.imagePadding = 7
        button.configuration?.title = title
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .systemFont(ofSize: 15, weight: .bold); return attributes
        }
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(button)
        let bottom = button.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        bottom.identifier = id + ".bottom"
        switch placement {
        case .center:
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: root.centerXAnchor), bottom,
                                         button.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16)])
        case .trailing:
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -16), bottom])
        }
        lift(button)
        // The mini player comes and goes with playback; follow it while the page is shown.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak button] timer in
            MainActor.assumeIsolated {
                guard let button, button.superview != nil else { timer.invalidate(); return }
                if button.window != nil { UIView.animate(withDuration: 0.2) { lift(button); button.superview?.layoutIfNeeded() } }
            }
        }
        return button
    }

    /// Sits just above whatever covers the bottom of the page: Spotify's mini player and tab bar
    /// (found by their class names), or the safe area when there are none.
    static func lift(_ button: UIButton) {
        guard let root = button.superview, let window = root.window, let id = button.accessibilityIdentifier,
              let bottom = root.constraints.first(where: { $0.identifier == id + ".bottom" }) else { return }
        root.bringSubviewToFront(button)
        let rootBottom = root.convert(root.bounds, to: window).maxY
        var cover = window.bounds.maxY - window.safeAreaInsets.bottom
        var queue: [UIView] = [window], seen = 0
        while !queue.isEmpty && seen < 4000 {
            let view = queue.removeFirst(); seen += 1
            guard !view.isHidden, view.alpha > 0.01, view !== root else { continue }
            let name = NSStringFromClass(type(of: view)).lowercased()
            if ["miniplayer", "nowplayingbar", "tabbar", "bottombar", "playerbar"].contains(where: name.contains) {
                let frame = view.convert(view.bounds, to: window)
                if frame.width >= window.bounds.width * 0.6, frame.height < 260, frame.maxY >= window.bounds.maxY - 300 { cover = min(cover, frame.minY) }
                continue
            }
            queue += view.subviews
        }
        bottom.constant = -(max(0, rootBottom - cover) + 12)
    }
}
