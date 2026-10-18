import SwiftUI

/// A left-to-right flow (wrap) layout: children are placed in rows,
/// wrapping to the next line when the container's width runs out —
/// the native counterpart of the web's `flex-wrap` chip strips.
public struct FlowLayout: Layout {
    public var spacing: CGFloat = 6
    public var rowSpacing: CGFloat = 6

    public init(spacing: CGFloat = 6, rowSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize,
                             subviews: Subviews,
                             cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth == .infinity ? widest : maxWidth),
                      height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect,
                              proposal: ProposedViewSize,
                              subviews: Subviews,
                              cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
