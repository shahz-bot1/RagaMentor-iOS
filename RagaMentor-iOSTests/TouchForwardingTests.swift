import XCTest
import SwiftUI
import SwiftData
import Combine
@testable import LoopLab
import PersistenceKit
import AudioKit

/// A silent ToneEngine for building a real SequencePlayer in
/// the page test (the controller's init requires one).
private final class SilentTone: ToneEngine {
    var samplesReady = true
    func prepare() async {}
    func playNote(semitone: Int, atOffset offset: Double, duration: Double) {}
    func stopAll() {}
}

// The scroll gate (ScrollGate.swift, v1.5.3): the container
// wrapping the song detail's scroll view declines touches
// over the wave strip while the page rests at the top, so
// they land on the waveform's own controls behind it. These
// hosting tests drive the real window hit-test — the path a
// real touch takes — over a replica and over the real page.
@MainActor
final class ScrollGateTests: XCTestCase {

    private func host<V: View>(_ view: V, in window: UIWindow) {
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        pump(window)
    }

    private func pump(_ window: UIWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.layoutIfNeeded()
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    // A replica of the detail's layering: the wave stand-in at
    // the back, the gated scroll view in front.
    private struct Replica: View {
        var body: some View {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(.blue)
                    .frame(height: 200)

                ScrollGateContainer(stripHeight: 200) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<40, id: \.self) { index in
                                Text("Row \(index)")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                        }
                        .padding(.top, 200)
                    }
                }
            }
        }
    }

    func testGatePassesStripTouchesToWaveAtRest() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host(Replica(), in: window)
        guard let scrollView = find(UIScrollView.self, in: window) else {
            XCTFail("no scroll view in the replica")
            return
        }
        scrollView.contentOffset = .zero
        pump(window)

        // On the strip, at rest: the gate declines, the hit
        // lands on the wave stand-in behind.
        let stripHit = window.hitTest(CGPoint(x: 195, y: 100), with: nil)
        XCTAssertNotNil(stripHit, "no hit at all on the strip")
        XCTAssertFalse(stripHit?.isDescendant(of: scrollView) ?? true,
                       "strip touch was claimed by the scroll view")

        // Below the strip: the scroll content owns the touch.
        let contentHit = window.hitTest(CGPoint(x: 195, y: 500), with: nil)
        XCTAssertTrue(contentHit?.isDescendant(of: scrollView) ?? false,
                      "touch below the strip did not reach the scroll content")
    }

    // The band rule (v1.5.6): with the page scrolled halfway
    // over the strip, the still-visible band forwards and the
    // covered band belongs to the content.
    func testGateForwardsOnlyTheVisibleBandWhenPartiallyScrolled() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host(Replica(), in: window)
        guard let scrollView = find(UIScrollView.self, in: window) else {
            XCTFail("no scroll view in the replica")
            return
        }
        // Scroll 100pt from rest, whatever rest is in this
        // harness (the rest offset is -adjustedContentInset.top
        // and settles asynchronously — an absolute offset, and
        // even an early rest read, overshoot by the inset; the
        // first two cuts of this test failed on exactly that).
        // Wait for the offset to stop moving before reading it.
        var lastY = scrollView.contentOffset.y
        for _ in 0..<20 {
            pump(window)
            let y = scrollView.contentOffset.y
            if y == lastY { break }
            lastY = y
        }
        let restY = scrollView.contentOffset.y
        scrollView.contentOffset = CGPoint(x: 0, y: restY + 100)
        pump(window)
        print("BANDTEST restY:", restY,
              "insetTop:", scrollView.adjustedContentInset.top,
              "offsetNow:", scrollView.contentOffset.y)

        // Strip is 200; scrolled 100 -> visible band is y < 100.
        let visibleHit = window.hitTest(CGPoint(x: 195, y: 50), with: nil)
        XCTAssertNotNil(visibleHit, "no hit on the visible band")
        XCTAssertFalse(visibleHit === scrollView
                       || (visibleHit?.isDescendant(of: scrollView) ?? true),
                       "touch on the visible band was claimed by the scroll view")
        // Covered band: probe where a row actually sits (row 1,
        // content y 244-288, lands around screen y 200-250 at
        // this scroll position for any harness inset). An
        // earlier cut probed the scroll view's empty padding
        // zone, whose hit is the scroll view itself — and
        // isDescendant(of:) is strict, so it read as a miss.
        let coveredHit = window.hitTest(CGPoint(x: 195, y: 225), with: nil)
        XCTAssertTrue(coveredHit === scrollView
                      || (coveredHit?.isDescendant(of: scrollView) ?? false),
                      "touch on the covered band did not reach the content")
    }

    func testGateClaimsStripOnceScrolled() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host(Replica(), in: window)
        guard let scrollView = find(UIScrollView.self, in: window) else {
            XCTFail("no scroll view in the replica")
            return
        }
        scrollView.contentOffset = CGPoint(x: 0, y: 300)
        pump(window)

        // Scrolled: content has slid over the strip and owns it.
        let hit = window.hitTest(CGPoint(x: 195, y: 100), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: scrollView) ?? false,
                      "strip touch was not claimed by the scrolled content")
    }

    func testRealDetailPageGatesToWaveControls() throws {
        let container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let song = Song(title: "Gate Song", contentHash: "gatehash",
                        fileRelativePath: "Audio/gatehash.mp3",
                        duration: 120, sampleRate: 44100, lastPosition: 0)
        container.mainContext.insert(song)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host(
            NavigationStack {
                SongDetailView(song: song)
            }
            .environmentObject(PlaybackController(
                sequencePlayer: SequencePlayer(tone: SilentTone())))
            .modelContainer(container),
            in: window)

        guard find(ScrollGateView.self, in: window) != nil else {
            XCTFail("the detail page has no scroll gate")
            return
        }
        guard let scrollView = find(UIScrollView.self, in: window) else {
            XCTFail("the detail page has no scroll view")
            return
        }
        scrollView.contentOffset = .zero
        pump(window)

        // Wave height at 700pt is 238; the Fit pill sits at the
        // strip's bottom-right. Its touch must pass the gate and
        // land on the wave area — NOT in the scroll view.
        let fitHit = window.hitTest(CGPoint(x: 360, y: 215), with: nil)
        XCTAssertNotNil(fitHit, "no hit at the Fit pill's position")
        XCTAssertFalse(fitHit?.isDescendant(of: scrollView) ?? true,
                       "the Fit pill's touch was claimed by the scroll view")

        // Below the strip, the page content owns the touch.
        let contentHit = window.hitTest(CGPoint(x: 195, y: 500), with: nil)
        XCTAssertTrue(contentHit?.isDescendant(of: scrollView) ?? false,
                      "touch below the strip did not reach the page content")
    }

    // The gate stack sits in front of the waveform, so every
    // layer of it must be transparent — v1.5.3 shipped with the
    // hosted scroll view painting an opaque background over
    // the wave (device report: controls worked, wave hidden).
    func testGateStackIsTransparent() throws {
        let container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let song = Song(title: "Gate Song", contentHash: "gatehash2",
                        fileRelativePath: "Audio/gatehash2.mp3",
                        duration: 120, sampleRate: 44100, lastPosition: 0)
        container.mainContext.insert(song)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        host(
            NavigationStack {
                SongDetailView(song: song)
            }
            .environmentObject(PlaybackController(
                sequencePlayer: SequencePlayer(tone: SilentTone())))
            .modelContainer(container),
            in: window)

        func isClear(_ view: UIView?) -> Bool {
            guard let color = view?.backgroundColor else { return true }
            var alpha: CGFloat = 0
            color.getWhite(nil, alpha: &alpha)
            return alpha == 0
        }

        let gate = find(ScrollGateView.self, in: window)
        XCTAssertNotNil(gate, "the detail page has no scroll gate")
        XCTAssertTrue(isClear(gate), "the gate view paints a background")
        XCTAssertTrue(isClear(gate?.subviews.first),
                      "the hosting view paints a background")
        let scrollView = find(UIScrollView.self, in: window)
        XCTAssertNotNil(scrollView, "the detail page has no scroll view")
        XCTAssertTrue(isClear(scrollView),
                      "the scroll view paints a background over the wave")
    }
}

// MARK: - Editor cover presentation (v1.5.7)

// The swara editor is presented as a full-screen cover from
// the host's root in BOTH studios (LoopLab and Compose, for
// consistency) — three stack-based forms failed on device in
// LoopLab while the same editor closed fine in Compose, whose
// parent is its root. These replicas mirror the shipped
// shapes and prove the property the cover exists for: opening
// and dismissing the editor never touches the stack
// underneath, so LoopLab returns to the song DETAIL.
@MainActor
final class EditorCoverNavigationTests: XCTestCase {

    private struct ProbeSession: Identifiable, Hashable {
        let id = UUID()
    }

    private final class Commands: ObservableObject {
        enum Action { case pushSong, openEditor, closeEditor, popSong }
        @Published var action: Action?
    }

    /// The LoopLab shape: a path-driven stack (songs only)
    /// plus a cover hosted at the root.
    private struct LoopLabReplica: View {
        @ObservedObject var commands: Commands
        @State private var path = NavigationPath()
        @State private var session: ProbeSession?

        var body: some View {
            NavigationStack(path: $path) {
                List { Text("SongRow") }
                    .navigationDestination(for: String.self) { _ in
                        Text("DetailPage")
                    }
                    .fullScreenCover(item: $session) { _ in
                        Text("EditorCover")
                    }
            }
            .onChange(of: commands.action) { _, action in
                switch action {
                case .pushSong: path.append("song-1")
                case .openEditor: session = ProbeSession()
                case .closeEditor: session = nil
                case .popSong: if !path.isEmpty { path.removeLast() }
                case nil: break
                }
                commands.action = nil
            }
        }
    }

    /// The Compose shape: a plain stack whose root IS the
    /// list, plus a cover hosted at the root.
    private struct ComposeReplica: View {
        @ObservedObject var commands: Commands
        @State private var session: ProbeSession?

        var body: some View {
            NavigationStack {
                List { Text("CompositionRow") }
                    .fullScreenCover(item: $session) { _ in
                        Text("EditorCover")
                    }
            }
            .onChange(of: commands.action) { _, action in
                switch action {
                case .openEditor: session = ProbeSession()
                case .closeEditor: session = nil
                default: break
                }
                commands.action = nil
            }
        }
    }

    private func findNavController(in controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        for child in controller.children {
            if let found = findNavController(in: child) { return found }
        }
        return nil
    }

    @discardableResult
    private func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func makeWindow<V: View>(_ view: V) -> (UIWindow, UIHostingController<V>) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, host)
    }

    func testLoopLabCoverDismissalReturnsToDetail() {
        let commands = Commands()
        let (window, host) = makeWindow(LoopLabReplica(commands: commands))
        _ = window
        guard let nav = findNavController(in: host) else {
            XCTFail("no navigation controller inside the replica")
            return
        }
        XCTAssertEqual(nav.viewControllers.count, 1, "should start at the list")

        commands.action = .pushSong
        XCTAssertTrue(waitFor { nav.viewControllers.count == 2 },
                      "the song push did not land")

        commands.action = .openEditor
        XCTAssertTrue(waitFor { host.presentedViewController != nil },
                      "the editor cover did not present")
        XCTAssertEqual(nav.viewControllers.count, 2,
                       "presenting the editor must not touch the stack")

        commands.action = .closeEditor
        XCTAssertTrue(waitFor { host.presentedViewController == nil },
                      "the editor cover did not dismiss")
        XCTAssertEqual(nav.viewControllers.count, 2,
                       "dismissing the editor must return to the DETAIL, not the list")

        commands.action = .popSong
        XCTAssertTrue(waitFor { nav.viewControllers.count == 1 },
                      "the detail should still pop back to the list normally")
    }

    func testComposeCoverDismissalReturnsToList() {
        let commands = Commands()
        let (window, host) = makeWindow(ComposeReplica(commands: commands))
        _ = window
        guard let nav = findNavController(in: host) else {
            XCTFail("no navigation controller inside the replica")
            return
        }
        XCTAssertEqual(nav.viewControllers.count, 1, "should start at the list")

        commands.action = .openEditor
        XCTAssertTrue(waitFor { host.presentedViewController != nil },
                      "the editor cover did not present")
        XCTAssertEqual(nav.viewControllers.count, 1,
                       "presenting the editor must not touch the stack")

        commands.action = .closeEditor
        XCTAssertTrue(waitFor { host.presentedViewController == nil },
                      "the editor cover did not dismiss")
        XCTAssertEqual(nav.viewControllers.count, 1,
                       "dismissing the editor must return to the list")
    }
}
