import SwiftUI

/// One swara token cell — the notation cell shared by the
/// Varisai lesson grid and the Raga detail scale rows (lifted
/// from Varisai, v1.5.9, so both studios render swaras with one
/// component and one highlight language). Equatable, so SwiftUI
/// skips re-rendering every cell whose highlight state did not
/// change. Text is the web's 13.5 pt; the current cell fills
/// with the accent and turns white.
public struct SwaraTokenCell: View, Equatable {
    public let text: String
    public let isCurrent: Bool
    /// Varisai's low-octave marker (a dashed rule). Raga rows
    /// pass false — raga tokens carry their octave in the label.
    public let isLow: Bool

    public init(text: String, isCurrent: Bool, isLow: Bool = false) {
        self.text = text
        self.isCurrent = isCurrent
        self.isLow = isLow
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 13.5, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isCurrent ? Studio.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isLow && !isCurrent ? Studio.muted.opacity(0.4)
                                                      : Color.clear,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .foregroundStyle(isCurrent ? .white : Studio.text)
    }
}

/// One group of swara cells in a single bordered box — the
/// Varisai grid's group form (panel fill, border, radius 9,
/// cells sharing the width equally). The Raga detail renders
/// one group per direction: the whole arohana (7–8 cells) or
/// avarohana as one group, like a laya span of that length.
/// `currentIndex` is local to the group; out-of-range values
/// highlight nothing.
public struct SwaraGroupRow: View {
    public let labels: [String]
    public let currentIndex: Int

    public init(labels: [String], currentIndex: Int) {
        self.labels = labels
        self.currentIndex = currentIndex
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { index in
                SwaraTokenCell(text: labels[index],
                               isCurrent: index == currentIndex)
                    .equatable()
            }
        }
        .padding(4)
        .frame(height: 40)
        .background(Studio.panel2, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Studio.border, lineWidth: 1))
    }
}
