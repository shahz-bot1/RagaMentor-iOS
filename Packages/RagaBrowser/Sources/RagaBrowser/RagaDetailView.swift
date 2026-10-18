import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// One raga's detail (web raga detail): the scale with its notation
/// toggle, the Listen card (Sa, tempo, one Play for arohana +
/// avarohana, test beep and status), the v14 display piano, allied
/// ragas and the Lakshana placeholder. In pick mode a "✓ Use this
/// raga" button applies the raga to the calling editor.
struct RagaDetailView: View {
    let raga: Raga
    let library: any RagaLibrary
    /// Plain value: the listen section observes the player, so this
    /// page no longer re-renders on every note pulse.
    let player: ScalePlayer
    var onPick: ((Raga) -> Void)?

    @State private var notation: Notation
    @State private var isFavourite: Bool

    private enum Notation: Hashable { case carnatic, hindustani }

    init(raga: Raga, library: any RagaLibrary, player: ScalePlayer,
         onPick: ((Raga) -> Void)?) {
        self.raga = raga
        self.library = library
        self.player = player
        self.onPick = onPick
        self._notation = State(initialValue: raga.isHindustani ? .hindustani : .carnatic)
        self._isFavourite = State(initialValue: library.isFavourite(sourceId: raga.id))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let onPick {
                    Button {
                        onPick(raga)
                    } label: {
                        Text("✓ Use this raga")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                }
                scaleCard
                RagaListenSection(raga: raga, player: player,
                                  hindustaniLabels: notation == .hindustani)
                alliedCard
                lakshanaCard
            }
            .padding(16)
        }
        .background(Studio.bg.ignoresSafeArea())
        .navigationTitle(raga.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Cards

    private var scaleCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(raga.name).font(.title3.weight(.semibold))
                        Text(metaLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isFavourite.toggle()
                        library.setFavourite(raga, favourited: isFavourite)
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(isFavourite ? Studio.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                StudioSegmented(items: [(Notation.carnatic, "Carnatic"),
                                        (.hindustani, "Hindustani")],
                                selection: $notation)
                scaleLine(label: "Arohana", tokens: raga.aro)
                scaleLine(label: "Avarohana", tokens: raga.ava)
            }
        }
    }

    private func scaleLine(label: String, tokens: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(tokens.map(display).joined(separator: " "))
                .font(.body)
        }
    }

    private func display(_ token: String) -> String {
        guard notation == .hindustani else { return token }
        if token.hasSuffix("'") || token.hasSuffix("′") {
            return ScaleNotation.hindustani(String(token.dropLast())) + "′"
        }
        return ScaleNotation.hindustani(token)
    }

    private var metaLine: String {
        if let n = raga.melakartaNumber {
            return "Melakarta \(n) · Chakra \(Melakarta.chakraName(forNumber: n)) · \(raga.jati ?? "")"
        }
        if let parent = raga.parentMelakarta {
            return "Janya of \(parent) · \(raga.jati ?? "")"
        }
        if let thaat = raga.thaat {
            return "Hindustani · Thaat \(thaat) · \(raga.jati ?? "")"
        }
        return raga.jati ?? ""
    }
}

/// A non-interactive chip look for navigation links (StudioChip is
/// a button; allied pills are links).
private struct StudioChipLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.border, lineWidth: 1))
            .foregroundStyle(Studio.text)
    }
}
