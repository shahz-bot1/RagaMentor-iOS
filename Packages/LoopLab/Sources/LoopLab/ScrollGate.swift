import SwiftUI
import UIKit

// The scroll gate (v1.5.3, Shahzin's design; band rule v1.5.6).
//
// The song detail's scroll view covers the waveform strip, so
// the wave's own controls could never be touched. Three
// forwarding designs (v1.4.5–v1.5.2) tried to hand the touches
// down from a layer above; all failed. The gate inverts it:
// the scroll view sits inside a thin container whose hit test
// DECLINES a touch when it lands on the part of the waveform
// strip that is still VISIBLE. The window's search then
// continues behind the container and lands on the waveform's
// real buttons and gestures. The covered part of the strip —
// and everything below it — belongs to the content, and once
// the content has scrolled past the whole strip the pinned
// header owns it.
//
// The check runs per touch, inside hitTest — nothing listens
// continuously, and the cost is a few comparisons.

/// Hosts a SwiftUI scroll view inside the gate container.
struct ScrollGateContainer<Content: View>: UIViewControllerRepresentable {
    let stripHeight: CGFloat
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> ScrollGateViewController<Content> {
        ScrollGateViewController(content: content(), stripHeight: stripHeight)
    }

    func updateUIViewController(_ controller: ScrollGateViewController<Content>, context: Context) {
        controller.setContent(content(), stripHeight: stripHeight)
    }
}

final class ScrollGateViewController<Content: View>: UIViewController {
    private let hosting: UIHostingController<Content>
    private var stripHeight: CGFloat

    init(content: Content, stripHeight: CGFloat) {
        hosting = UIHostingController(rootView: content)
        self.stripHeight = stripHeight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        // Transparent at every layer: the gate stack sits IN
        // FRONT of the waveform, and a hosted scroll view
        // otherwise paints an opaque background over it
        // (v1.5.3 device report: controls worked, wave hidden).
        let gate = ScrollGateView()
        gate.backgroundColor = .clear
        gate.isOpaque = false
        view = gate
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? ScrollGateView)?.stripHeight = stripHeight
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.isOpaque = false
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    func setContent(_ content: Content, stripHeight: CGFloat) {
        hosting.rootView = content
        self.stripHeight = stripHeight
        (viewIfLoaded as? ScrollGateView)?.stripHeight = stripHeight
    }
}

/// The gate itself: a plain container view that declines
/// strip touches at rest.
final class ScrollGateView: UIView {
    /// The height of the waveform strip at the top.
    var stripHeight: CGFloat = 0
    private weak var scrollView: UIScrollView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if point.y >= 0, let scrollView = resolvedScrollView() {
            // How far the content has scrolled over the strip:
            // 0 at rest, negative on a pull-down. The visible
            // band of the wave is the strip minus that much,
            // clamped so a pull-down never widens it past the
            // strip itself.
            let over = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let visibleBand = min(stripHeight, stripHeight - over)
            if point.y < visibleBand {
                // Over the visible wave: not ours. The search
                // continues behind us, to the waveform.
                return nil
            }
        }
        return super.hitTest(point, with: event)
    }

    private func resolvedScrollView() -> UIScrollView? {
        if let scrollView, scrollView.window != nil { return scrollView }
        var found: UIScrollView?
        func walk(_ view: UIView) {
            guard found == nil else { return }
            if let candidate = view as? UIScrollView {
                found = candidate
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(self)
        scrollView = found
        return found
    }
}
