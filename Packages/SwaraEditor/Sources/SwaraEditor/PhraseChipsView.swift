import SwiftUI
import RagaCore
import DesignSystem

/// One phrase chip: the swara label with its duration sub-label. The
/// current (playing) chip gets the tinted highlight — accent border and
/// a translucent accent fill (web .fchip.cur).
public struct PhraseChipView: View {
    public var chip: Chip
    public var isCurrent: Bool = false

    public init(chip: Chip, isCurrent: Bool = false) {
        self.chip = chip
        self.isCurrent = isCurrent
    }

    public var body: some View {
        VStack(spacing: 1) {
            Text(SwaraLabel.chipLabel(chip))
                .font(.callout.weight(.medium))
                .foregroundStyle(chip.kind == .note ? .primary : .secondary)
            Text(Swara.durationLabel(chip.beats))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isCurrent ? Studio.accentSoft : Studio.panel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isCurrent ? Studio.accent : Studio.border,
                        lineWidth: isCurrent ? 1.5 : 1)
        )
    }
}

/// The read-only chip strip (editor Phrase card and the LoopLab Swaras
/// section): chips scroll horizontally; an optional ＋ tile appends.
public struct PhraseChipsView: View {
    public var chips: [Chip]
    public var currentIndex: Int = -1
    public var onTapChip: ((Int) -> Void)?
    public var onTapAdd: (() -> Void)?

    public init(chips: [Chip], currentIndex: Int = -1,
                onTapChip: ((Int) -> Void)? = nil, onTapAdd: (() -> Void)? = nil) {
        self.chips = chips
        self.currentIndex = currentIndex
        self.onTapChip = onTapChip
        self.onTapAdd = onTapAdd
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    PhraseChipView(chip: chip, isCurrent: index == currentIndex)
                        .onTapGesture { onTapChip?(index) }
                }
                if let onTapAdd {
                    Text("＋")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Studio.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                        .onTapGesture { onTapAdd() }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
