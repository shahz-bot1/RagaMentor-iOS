import SwiftUI
import UIKit

/// Touch forwarding for the song detail (his chosen fix for the
/// dead waveform controls): the pinned-scroll ScrollView is the
/// FRONT layer of the detail's ZStack and owns the whole screen,
/// so the waveform behind it — its Follow/Fit buttons, the armed
/// loop badge, and its tap-seek / pinch gestures — never saw a
/// touch. A layer swap was rejected: content must keep sliding
/// OVER the wave and the playback header must keep docking at
/// the top, not under the wave.
///
/// This transparent view sits as the ZStack's top child. Its
/// hitTest forwards a touch to the waveform subtree when (a) the
/// scroll view rests at the top, so the wave strip is actually
/// uncovered, and (b) the point lands on a real interactive
/// subview of the wave. Every other touch returns nil and falls
/// through to the scroll view untouched — scrolling, the pinned
/// header, and content sliding over the wave behave exactly as
/// before.
struct TouchForwardingOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchForwardingView {
        let view = TouchForwardingView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TouchForwardingView, context: Context) {}
}

final class TouchForwardingView: UIView {
    private weak var scrollView: UIScrollView?
    private weak var waveView: UIView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        wire()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView == nil || waveView == nil { wire() }
    }

    /// Find the two siblings this view shares the ZStack with:
    /// climb to the first ancestor whose direct subtrees separate
    /// this view from a scroll view; the remaining subtree is the
    /// waveform area. Wrapper views SwiftUI inserts around
    /// children are absorbed by the subtree test.
    private func wire() {
        var ancestor = superview
        while let container = ancestor {
            let subs = container.subviews
            let selfSide = subs.first { $0 === self || isDescendant(of: $0) }
            let scrollSide = subs.first {
                $0 !== selfSide && Self.firstScrollView(in: $0) != nil
            }
            if let selfSide, let scrollSide {
                scrollView = Self.firstScrollView(in: scrollSide)
                waveView = subs.first { $0 !== selfSide && $0 !== scrollSide }
                return
            }
            ancestor = container.superview
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if scrollView?.window == nil || waveView?.window == nil { wire() }
        guard let scrollView, let waveView else { return nil }
        // Forward only at rest at the top: once the content has
        // slid over the wave, the strip belongs to the content and
        // the pinned header.
        let topOffset = -scrollView.adjustedContentInset.top
        guard scrollView.contentOffset.y <= topOffset + 1 else { return nil }
        let converted = convert(point, to: waveView)
        guard waveView.bounds.contains(converted) else { return nil }
        // The wave container itself is not interactive — only a
        // real subview hit (the wave, a badge, a button) forwards.
        // Anything else (padding, dead space) falls through to
        // the scroll view, so a drag there still scrolls.
        guard let hit = waveView.hitTest(converted, with: event),
              hit !== waveView else { return nil }
        return hit
    }
}
