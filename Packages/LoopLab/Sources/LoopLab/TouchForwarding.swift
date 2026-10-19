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
/// v1.4.5's first attempt guessed the view hierarchy (sibling
/// classification inside the ZStack) and never engaged on
/// device. This version wires explicit references instead:
/// probes placed on the real views resolve the scroll view and
/// the waveform's container and publish them to a shared
/// TouchRouting; the forwarding view (the ZStack's top child)
/// consults it. A hosting test in the app test target exercises
/// the hit-testing in a real window, so the mechanism is
/// verified, not assumed.
///
/// Behaviour: a touch forwards to the waveform subtree when
/// (a) the scroll view rests at the top, so the wave strip is
/// actually uncovered, and (b) the point lands on a real
/// interactive subview of the wave. Every other touch returns
/// nil and falls through to the scroll view untouched —
/// scrolling, the pinned header, and content sliding over the
/// wave behave exactly as before.
final class TouchRouting {
    weak var scrollView: UIScrollView?
    weak var waveRoot: UIView?
}

/// A zero-footprint probe view: resolves one reference for the
/// routing when it joins a window, then stays out of the way.
final class ProbeUIView: UIView {
    enum Kind {
        /// Walk up to the first UIScrollView ancestor.
        case scroll
        /// The wave container: the highest ancestor no taller
        /// than the wave area itself.
        case wave(CGFloat)
    }

    var routing: TouchRouting?
    var kind: Kind = .scroll

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { resolve() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { resolve() }
    }

    private func resolve() {
        guard let routing else { return }
        switch kind {
        case .scroll:
            var node = superview
            while let view = node {
                if let scroll = view as? UIScrollView {
                    routing.scrollView = scroll
                    return
                }
                node = view.superview
            }
        case .wave(let height):
            var candidate: UIView?
            var node = superview
            while let view = node {
                guard view.bounds.height <= height + 1 else { break }
                candidate = view
                node = view.superview
            }
            if let candidate { routing.waveRoot = candidate }
        }
    }
}

struct ScrollProbe: UIViewRepresentable {
    let routing: TouchRouting

    func makeUIView(context: Context) -> ProbeUIView {
        let view = ProbeUIView()
        view.kind = .scroll
        view.routing = routing
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeUIView, context: Context) {
        uiView.routing = routing
    }
}

struct WaveProbe: UIViewRepresentable {
    let routing: TouchRouting
    let waveHeight: CGFloat

    func makeUIView(context: Context) -> ProbeUIView {
        let view = ProbeUIView()
        view.kind = .wave(waveHeight)
        view.routing = routing
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeUIView, context: Context) {
        uiView.routing = routing
        uiView.kind = .wave(waveHeight)
    }
}

struct TouchForwardingOverlay: UIViewRepresentable {
    let routing: TouchRouting

    func makeUIView(context: Context) -> TouchForwardingView {
        let view = TouchForwardingView()
        view.backgroundColor = .clear
        view.routing = routing
        return view
    }

    func updateUIView(_ uiView: TouchForwardingView, context: Context) {
        uiView.routing = routing
    }

    /// Fill the space offered (the whole ZStack): a representable
    /// with no intrinsic size can otherwise end up with a frame
    /// too small for its hitTest to ever be consulted — the
    /// v1.4.5 failure mode.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: TouchForwardingView,
                      context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class TouchForwardingView: UIView {
    var routing: TouchRouting?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let scrollView = routing?.scrollView,
              let waveRoot = routing?.waveRoot,
              scrollView.window != nil, waveRoot.window != nil else { return nil }
        // Forward only at rest at the top: once the content has
        // slid over the wave, the strip belongs to the content
        // and the pinned header.
        let topOffset = -scrollView.adjustedContentInset.top
        guard scrollView.contentOffset.y <= topOffset + 1 else { return nil }
        let converted = convert(point, to: waveRoot)
        guard waveRoot.bounds.contains(converted) else { return nil }
        // The wave container itself is not interactive — only a
        // real subview hit (the wave, a badge, a button)
        // forwards. Anything else (padding, dead space) falls
        // through to the scroll view, so a drag there scrolls.
        guard let hit = waveRoot.hitTest(converted, with: event),
              hit !== waveRoot else { return nil }
        return hit
    }
}
