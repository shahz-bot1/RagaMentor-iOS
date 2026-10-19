import XCTest
import SwiftUI
import UIKit
@testable import LoopLab

/// The song detail's touch forwarding, exercised in a real
/// window against a replica of its ZStack shape (wave area with
/// a button at the back, the page ScrollView in front, the
/// forwarding layer on top). v1.4.5 shipped this mechanism
/// unverified and it never engaged on device; these tests pin
/// the wiring and the hit-test contract in three separately
/// named checks, so a failure says which link broke.
@MainActor
final class TouchForwardingTests: XCTestCase {

    private struct Replica: View {
        let routing: TouchRouting

        var body: some View {
            ZStack(alignment: .top) {
                Button("Wave") {}
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(WaveProbe(routing: routing))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<60, id: \.self) { i in
                            Text("Row \(i)").frame(height: 30)
                        }
                    }
                    .background(ScrollProbe(routing: routing))
                }

                TouchForwardingOverlay(routing: routing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct Hosted {
        let routing: TouchRouting
        let window: UIWindow
        let forwarder: TouchForwardingView?
    }

    private func host() -> Hosted {
        let routing = TouchRouting()
        let host = UIHostingController(rootView: Replica(routing: routing))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return Hosted(routing: routing, window: window,
                      forwarder: findForwarder(in: host.view))
    }

    private func findForwarder(in view: UIView) -> TouchForwardingView? {
        if let forwarder = view as? TouchForwardingView { return forwarder }
        for sub in view.subviews {
            if let found = findForwarder(in: sub) { return found }
        }
        return nil
    }

    func testProbesResolveAndLayerFills() {
        let hosted = host()
        XCTAssertNotNil(hosted.routing.scrollView,
                        "scroll probe did not resolve a UIScrollView")
        XCTAssertNotNil(hosted.routing.waveProbe,
                        "wave probe did not publish itself")
        XCTAssertNotNil(hosted.forwarder?.waveRoot,
                        "wave container not derivable from the probes")
        guard let forwarder = hosted.forwarder else {
            XCTFail("no TouchForwardingView in the hosted hierarchy")
            return
        }
        // The forwarding layer fills the detail (v1.4.5's silent
        // failure was a frame too small to ever be consulted).
        XCTAssertGreaterThan(forwarder.bounds.width, 300)
        XCTAssertGreaterThan(forwarder.bounds.height, 600)
    }

    func testForwardsToWaveAtRest() {
        let hosted = host()
        guard let forwarder = hosted.forwarder,
              let scrollView = hosted.routing.scrollView,
              let waveRoot = forwarder.waveRoot else {
            XCTFail("hosting prerequisites missing (see testProbesResolveAndLayerFills)")
            return
        }
        scrollView.contentOffset = .zero
        let hit = forwarder.hitTest(CGPoint(x: 195, y: 100), with: nil)
        XCTAssertNotNil(hit, "touch on the wave was not forwarded")
        XCTAssertTrue(hit?.isDescendant(of: waveRoot) ?? false,
                      "forwarded hit is not inside the wave subtree")
    }

    func testPassesThroughWhenScrolledOrBelowWave() {
        let hosted = host()
        guard let forwarder = hosted.forwarder,
              let scrollView = hosted.routing.scrollView else {
            XCTFail("hosting prerequisites missing (see testProbesResolveAndLayerFills)")
            return
        }
        let wavePoint = CGPoint(x: 195, y: 100)
        scrollView.contentOffset = CGPoint(x: 0, y: 300)
        XCTAssertNil(forwarder.hitTest(wavePoint, with: nil),
                     "touch forwarded while the content covers the wave")
        scrollView.contentOffset = .zero
        XCTAssertNil(forwarder.hitTest(CGPoint(x: 195, y: 400), with: nil),
                     "touch below the wave was forwarded")
    }
}
