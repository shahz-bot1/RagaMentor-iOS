import SwiftUI
import AudioKit
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
/// section): chips WRAP onto the next line like the web's flex-wrap
/// strips; an optional ＋ tile appends into the flow.
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

    private enum FlowItem: Identifiable {
        case chip(Int)
        case add
        var id: String {
            switch self {
            case .chip(let i): return "chip-\(i)"
            case .add: return "add"
            }
        }
    }

    public var body: some View {
        var items: [FlowItem] = chips.indices.map { .chip($0) }
        if onTapAdd != nil { items.append(.add) }
        return FlowStack(items: items, spacing: 6, rowSpacing: 6) { item in
            switch item {
            case .chip(let index):
                PhraseChipView(chip: chips[index], isCurrent: index == currentIndex)
                    .onTapGesture { onTapChip?(index) }
            case .add:
                Text("＋")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Studio.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .onTapGesture { onTapAdd?() }
            }
        }
    }
}

/// The live chip strip, behind a PlaybackGate (v1.5.29 — his
/// scoping rule: subscribe only when required). The strip used
/// to observe the player itself, so any pass anywhere re-ran it;
/// now the gate is the only observer and the strip re-renders
/// only while its own context plays on a visible screen. The
/// host takes the player as a plain value, as before.
public struct LivePhraseChipsView: View {
    private let player: SequencePlayer
    public var chips: [Chip]
    public var contextKey: String
    /// Whether the hosting screen is visible (the editor cover
    /// passes true — it is the top screen while it lives; the
    /// LoopLab detail passes its page visibility).
    public var visible: Bool
    public var onTapChip: ((Int) -> Void)?
    public var onTapAdd: (() -> Void)?

    public init(player: SequencePlayer, chips: [Chip], contextKey: String,
                visible: Bool = true,
                onTapChip: ((Int) -> Void)? = nil, onTapAdd: (() -> Void)? = nil) {
        self.player = player
        self.chips = chips
        self.contextKey = contextKey
        self.visible = visible
        self.onTapChip = onTapChip
        self.onTapAdd = onTapAdd
    }

    public var body: some View {
        PlaybackGate(player: player, contextKey: contextKey,
                     visible: visible) { _, index in
            PhraseChipsView(
                chips: chips,
                currentIndex: index,
                onTapChip: onTapChip,
                onTapAdd: onTapAdd)
        }
    }
}
