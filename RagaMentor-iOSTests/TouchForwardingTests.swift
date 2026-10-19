import XCTest
import SwiftUI
import UIKit
@testable import LoopLab

/// The song detail's touch forwarding, exercised in a real
/// window against a replica of its ZStack shape (wave area with
/// a button at the back, the page ScrollView in front, the
/// forwarding layer on top). v1.4.5 shipped this mechanism
/// unverified and it never engaged on device; these tests pin
/// the wiring (probes resolve, the layer fills its frame) and
/// the hit-test contract (forward at rest, pass through when
/// scrolled or below the wave).
@MainActor
final class TouchForwardingTests: XCTestCase {

    private struct Replica: View {
        let routing: TouchRouting

        var body: some View {
            ZStack(alignment: .top) {
                Button("Wave") {}
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(WaveProbe(routing: routing, waveHeight: 200))

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

    private func findForwarder(in view: UIView) -> TouchForwardingView? {
        if let forwarder = view as? TouchForwardingView { return forwarder }
        for sub in view.subviews {
            if let found = findForwarder(in: sub) { return found }
        }
        return nil
    }

    func testForwardsToWaveAtRestAndPassesThroughOtherwise() {
        let routing = TouchRouting()
        let host = UIHostingController(rootView: Replica(routing: routing))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        // The probes resolved both references from the real
        // hierarchy.
        XCTAssertNotNil(routing.scrollView, "scroll probe did not resolve a UIScrollView")
        XCTAssertNotNil(routing.waveRoot, "wave probe did not resolve the wave container")
        guard let scrollView = routing.scrollView, let waveRoot = routing.waveRoot else { return }

        guard let forwarder = findForwarder(in: host.view) else {
            XCTFail("no TouchForwardingView in the hosted hierarchy")
            return
        }
        // The forwarding layer fills the detail (v1.4.5's silent
        // failure was a frame too small to ever be consulted).
        XCTAssertGreaterThan(forwarder.bounds.width, 300)
        XCTAssertGreaterThan(forwarder.bounds.height, 600)

        // At rest, a touch on the wave's button forwards to a
        // view inside the wave subtree.
        scrollView.contentOffset = .zero
        let wavePoint = CGPoint(x: 195, y: 100)
        let hit = forwarder.hitTest(wavePoint, with: nil)
        XCTAssertNotNil(hit, "touch on the wave was not forwarded")
        XCTAssertTrue(hit?.isDescendant(of: waveRoot) ?? false,
                      "forwarded hit is not inside the wave subtree")

        // Scrolled (content over the wave): no forwarding.
        scrollView.contentOffset = CGPoint(x: 0, y: 300)
        XCTAssertNil(forwarder.hitTest(wavePoint, with: nil),
                     "touch forwarded while the content covers the wave")

        // Below the wave strip: no forwarding even at rest.
        scrollView.contentOffset = .zero
        XCTAssertNil(forwarder.hitTest(CGPoint(x: 195, y: 400), with: nil),
                     "touch below the wave was forwarded")
    }
}
