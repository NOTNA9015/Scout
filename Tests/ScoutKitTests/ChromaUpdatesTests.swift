import XCTest
import SwiftUI
import UIKit
import ObjectiveC
@testable import ScoutKit

/// The Chroma | Scout switch in Chroma's Update tab, and Scout answering Chroma's IPA picker.
@MainActor final class ChromaUpdatesTests: XCTestCase {
    var work: URL!
    var window: UIWindow!

    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        // Never asks GitHub: every request is a 404, so the updater is up to date.
        let updater = ScoutUpdater(installed: work.appendingPathComponent("ScoutKit.framework"), appBundle: work,
                                   support: work.appendingPathComponent("Support"), documents: work.appendingPathComponent("Docs"))
        updater.get = { url in (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        ChromaUpdates.updater = { updater }
        ChromaUpdates.pending = nil
    }
    override func tearDown() async throws {
        window.isHidden = true; window = nil
        ChromaUpdates.updater = { .shared }
        ChromaUpdates.pending = nil
        try? FileManager.default.removeItem(at: work)
    }

    /// A stand-in for Chroma's PickerDelegate, under its real class name, keeping what it's handed.
    final class Received { var urls: [[URL]] = [] }
    static let received = Received()
    static let chromaPicker: AnyClass = {
        if let existing = NSClassFromString(ChromaHook.pickerClassName) { return existing }
        let cls: AnyClass = objc_allocateClassPair(NSObject.self, ChromaHook.pickerClassName, 0)!
        let block: @convention(block) (AnyObject, AnyObject, NSArray) -> Void = { _, _, urls in received.urls.append(urls.compactMap { $0 as? URL }) }
        class_addMethod(cls, ChromaHook.manySelector, imp_implementationWithBlock(block), "v@:@@")
        class_addProtocol(cls, objc_getProtocol("UIDocumentPickerDelegate")!)
        objc_registerClassPair(cls)
        return cls
    }()

    func testChromasPickerIsAnsweredWithScoutsIPAInsteadOfShowingFiles() throws {
        let delegate = (Self.chromaPicker as! NSObject.Type).init()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        picker.delegate = delegate as? UIDocumentPickerDelegate
        objc_setAssociatedObject(picker, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        let before = Self.received.urls.count

        XCTAssertFalse(ChromaUpdates.answer(picker), "nothing to hand over: Files shows")
        let ipa = work.appendingPathComponent("Spotify 9.1.98 + Scout 0.1.3.ipa")
        ChromaUpdates.pending = ipa
        XCTAssertTrue(ChromaUpdates.answer(picker), "answered, so the picker is never shown")
        XCTAssertEqual(Self.received.urls.count, before + 1)
        XCTAssertEqual(Self.received.urls.last, [ipa])
        XCTAssertNil(ChromaUpdates.pending)
        XCTAssertFalse(ChromaUpdates.answer(picker), "only once: asking again opens Files")

        // Other pickers are left alone.
        ChromaUpdates.pending = ipa
        let other = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        XCTAssertFalse(ChromaUpdates.answer(other))
        XCTAssertFalse(ChromaUpdates.answer(UIViewController()))
        XCTAssertEqual(ChromaUpdates.pending, ipa)
    }

    /// Scout opens Chroma's Spotify row as VoiceOver would, with no accessibility client running
    /// and Chroma's page hidden behind Scout's side, and leaves app accessibility as it found it.
    func testChromasSpotifyRowIsOpenedThroughAccessibility() async throws {
        final class Taps { var spotify = 0, other = 0 }
        let taps = Taps()
        let host = UIHostingController(rootView: ScrollView {
            VStack(spacing: 20) {
                Text("Chroma 1.1.0").font(.largeTitle)
                Button { taps.other += 1 } label: { HStack { Image(systemName: "checkmark.seal"); Text("Certificate"); Spacer(); Text("Add") } }
                Button { taps.spotify += 1 } label: { HStack { Image(systemName: "music.note"); Text("Spotify"); Spacer(); Text("9.1.98") } }
            }.padding()
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        let page = try XCTUnwrap(ChromaUpdates.chromaContent(in: host.view), "Chroma's scrolling page")
        page.alpha = 0
        let before = AppAccessibility.isOn

        let opened = await ChromaUpdates.openChromasPicker(in: host.view) { taps.spotify > 0 }
        XCTAssertTrue(opened)
        XCTAssertEqual(taps.spotify, 1)
        XCTAssertEqual(taps.other, 0)
        XCTAssertEqual(AppAccessibility.isOn, before, "app accessibility is back as it was")
    }

    /// The switch goes on Chroma's updater page only; Scout's side hides Chroma's scrolling page.
    func testTheSwitchShowsScoutsSideOverChromasPage() async throws {
        let name = "_TtGC7SwiftUI19UIHostingControllerVO12spotifyglass9SGUpdater10UpdateView_"
        let cls: AnyClass = NSClassFromString(name) ?? {
            let made: AnyClass = objc_allocateClassPair(UIViewController.self, name, 0)!
            objc_registerClassPair(made)
            return made
        }()
        let page = (cls as! UIViewController.Type).init()
        let content = UIScrollView(frame: window.bounds)
        page.view.addSubview(content)
        window.rootViewController = page
        window.makeKeyAndVisible()
        XCTAssertTrue(ChromaUpdates.isUpdater(page))
        XCTAssertFalse(ChromaUpdates.isUpdater(UIViewController()))

        ChromaUpdates.attach(to: page)
        ChromaUpdates.attach(to: page)
        let root = try XCTUnwrap(page.viewIfLoaded)
        let toggle = try XCTUnwrap(ScoutEntry.find(root, id: ChromaUpdates.switchID))
        let panel = try XCTUnwrap(ScoutEntry.find(root, id: ChromaUpdates.panelID))
        XCTAssertEqual(root.subviews.filter { $0.accessibilityIdentifier == ChromaUpdates.switchID }.count, 1, "added once")
        XCTAssertTrue(panel.isHidden, "Chroma's side first")
        XCTAssertEqual(content.alpha, 1)
        root.layoutIfNeeded()
        XCTAssertLessThan(toggle.frame.minY, 140, "the switch sits at the top, beside Chroma's close button")

        let paths = try XCTUnwrap(ChromaUpdates.paths)
        paths.path = .scout
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(panel.isHidden)
        XCTAssertEqual(content.alpha, 0, "Chroma's page is hidden behind Scout's side")
        XCTAssertLessThanOrEqual(panel.frame.maxY, root.bounds.maxY - ChromaUpdates.bottomReserve + 0.5, "Chroma's slider stays visible")

        paths.path = .chroma
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(panel.isHidden)
        XCTAssertEqual(content.alpha, 1)
    }
}
