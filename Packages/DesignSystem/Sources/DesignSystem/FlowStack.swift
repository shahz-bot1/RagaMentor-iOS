import SwiftUI

/// A wrapping row layout for content-sized chips (the web's
/// flex-wrap), built from plain containers: each item is measured
/// once through a background preference pass, then rows are built
/// greedily as HStacks in a VStack. Container sizing is therefore
/// ordinary SwiftUI container math — an earlier Layout-protocol
/// version could under-report its height when an ancestor proposed
/// a different width for measuring than for placement, which
/// clipped rows inside cards.
public struct FlowStack<Item: Identifiable, Content: View>: View {
    public var items: [Item]
    public var spacing: CGFloat = 8
    public var rowSpacing: CGFloat = 8
    @ViewBuilder public var content: (Item) -> Content

    @State private var sizes: [AnyHashable: CGSize] = [:]
    @State private var containerWidth: CGFloat = 0

    public init(items: [Item], spacing: CGFloat = 8, rowSpacing: CGFloat = 8,
                @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content
    }

    private struct SizeKey: PreferenceKey {
        static var defaultValue: [AnyHashable: CGSize] { [:] }
        static func reduce(value: inout [AnyHashable: CGSize],
                           nextValue: () -> [AnyHashable: CGSize]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: spacing) {
                    ForEach(rows[rowIndex]) { item in
                        content(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in containerWidth = w }
        })
        .background(measureLayer)
        .onPreferenceChange(SizeKey.self) { sizes = $0 }
    }

    /// All items in one fixed-size row, hidden, purely to learn
    /// their ideal widths. Backgrounds never affect the parent's
    /// size, and hit testing is off.
    private var measureLayer: some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                content(item)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: SizeKey.self,
                            value: [AnyHashable(item.id): geo.size])
                    })
            }
        }
        .fixedSize()
        .hidden()
        .allowsHitTesting(false)
    }

    private var rows: [[Item]] {
        guard containerWidth > 0 else { return [items] }
        var out: [[Item]] = []
        var row: [Item] = []
        var rowWidth: CGFloat = 0
        for item in items {
            let w = sizes[AnyHashable(item.id)]?.width ?? 0
            let added = row.isEmpty ? w : w + spacing
            if !row.isEmpty, rowWidth + added > containerWidth {
                out.append(row)
                row = [item]
                rowWidth = w
            } else {
                row.append(item)
                rowWidth += added
            }
        }
        if !row.isEmpty { out.append(row) }
        return out
    }
}
