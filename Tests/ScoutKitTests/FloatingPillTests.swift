import XCTest
import UIKit
@testable import ScoutKit

/// Spotify's full-screen container: its class comes from Spotify's tab bar module, so it is named
/// like a bar, and the tab bar and Chroma's players are inside it.
private final class MainUITabBarTouchForwardingView: UIView {}
private final class TabBarView: UIView {}
private final class TabBarGradientView: UIView {}
private final class NowPlayingBarView: UIView {}

/// The Scout pill keeps clear of the mini player, whichever one Chroma shows.
@MainActor final class FloatingPillTests: XCTestCase {
    var window: UIWindow!
    var container: UIView!
    var page: UIView!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        container = MainUITabBarTouchForwardingView(frame: window.bounds)
        window.rootViewController?.view.addSubview(container)
        page = UIView(frame: container.bounds)
        container.addSubview(page)
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    func pill() -> UIButton {
        let button = FloatingPill.make(id: "test.pill", title: "Scout", symbol: "sparkles", placement: .trailing, in: page)
        FloatingPill.lift(button)
        page.layoutIfNeeded()
        return button
    }
    func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }

    /// Chroma's "Music app style": the system tab bar, with the mini player as its accessory.
    func testSitsAboveTheMusicAppStyleMiniPlayer() async throws {
        let tabs = UITabBarController()
        tabs.viewControllers = [UIViewController(), UIViewController()]
        for (index, tab) in (tabs.viewControllers ?? []).enumerated() { tab.tabBarItem = UITabBarItem(title: "Tab \(index)", image: UIImage(systemName: "house"), tag: index) }
        let miniPlayer = UILabel()
        miniPlayer.text = "Song • Artist"
        tabs.bottomAccessory = UITabAccessory(contentView: miniPlayer)
        let host = UIView(frame: container.bounds)
        container.addSubview(host)
        window.rootViewController?.addChild(tabs)
        tabs.view.frame = host.bounds
        tabs.view.backgroundColor = .clear
        host.addSubview(tabs.view)
        tabs.didMove(toParent: window.rootViewController)
        try await Task.sleep(for: .milliseconds(800))

        let player = frame(miniPlayer), button = frame(pill())
        XCTAssertGreaterThan(player.height, 0)
        XCTAssertLessThan(player.maxY, window.bounds.maxY - window.safeAreaInsets.bottom, "the accessory sits above the tab bar")
        XCTAssertLessThanOrEqual(button.maxY, player.minY, "pill \(button) overlaps the mini player \(player)")
        XCTAssertGreaterThan(button.maxY, player.minY - 30, "pill \(button) should sit just above the mini player \(player)")
    }

    /// Spotify's own mini player sits outside the container, the tab bar and its fade inside it;
    /// the pill stays just above the mini player, over the fade.
    func testStaysJustAboveSpotifysMiniPlayer() async throws {
        let width = window.bounds.width, bottom = window.bounds.maxY
        container.addSubview(TabBarGradientView(frame: CGRect(x: 0, y: bottom - 219, width: width, height: 219)))
        container.addSubview(TabBarView(frame: CGRect(x: 0, y: bottom - 83, width: width, height: 83)))
        let miniPlayer = NowPlayingBarView(frame: CGRect(x: 8, y: bottom - 147, width: width - 16, height: 56))
        window.rootViewController?.view.addSubview(miniPlayer)

        XCTAssertEqual(frame(pill()).maxY, frame(miniPlayer).minY - 12, accuracy: 0.5)
    }
}
