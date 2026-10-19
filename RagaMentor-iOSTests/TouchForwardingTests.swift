import XCTest
import SwiftUI
import SwiftData
@testable import LoopLab
import PersistenceKit

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
            .environmentObject(PlaybackController())
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
}
