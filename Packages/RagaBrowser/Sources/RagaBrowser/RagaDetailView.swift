import SwiftUI
import RagaCore
import AudioKit
import DesignSystem

/// One raga's detail (web raga detail): the scale as two
/// Varisai-style swara group rows with its notation toggle, the
/// Listen card (Sa, tempo, one Play for arohana + avarohana),
/// the display piano, allied ragas and the Lakshana placeholder.
/// In pick mode a "✓ Use this raga" button applies the raga to
/// the calling editor.
struct RagaDetailView: View {
    let raga: Raga
    let library: any RagaLibrary
    /// Plain value: the listen section observes the adapter's
    /// player, so this page no longer re-renders on every note pulse.
    let adapter: ScaleAdapter
    var onPick: ((Raga) -> Void)?

    @State private var notation: Notation
    @State private var isFavourite: Bool

    private enum Notation: Hashable { case carnatic, hindustani }

    init(raga: Raga, library: any RagaLibrary, adapter: ScaleAdapter,
         onPick: ((Raga) -> Void)?) {
        self.raga = raga
        self.library = library
        self.adapter = adapter
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
                RagaListenSection(raga: raga, adapter: adapter, player: adapter.player,
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
                RagaSwaraRows(player: adapter.player,
                              aro: raga.aro.map(display),
                              ava: raga.ava.map(display))
            }
        }
    }

    private func display(_ token: String) -> String {
        guard notation == .hindustani else { return token }
        if token.hasSuffix("'") || token.hasSuffix("′") {
            return ScaleNotation.hindustani(String(token.dropLast())) + "′"
        }
        return ScaleNotation.hindustani(token)
    }

    private var alliedCard: some View {
        let resolved = raga.allied.compactMap { name in
            RagaCatalog.all.first { $0.name == name }
        }
        return Group {
            if !resolved.isEmpty {
                StudioCard {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioSectionTitle("Allied ragas · sounds like")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(resolved, id: \.id) { allied in
                                NavigationLink(value: allied.id) {
                                    StudioChipLabel(title: allied.name)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var lakshanaCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 6) {
                StudioSectionTitle("Lakshana · curated in v1")
                Text("Vadi / samvadi, anya swaras, jeeva swaras and compositions land here once the dataset is curated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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

/// The scale as two Varisai-style group rows — one group per
/// direction, each swara its own cell (v1.5.9, the web raga
/// page's highlighted swara rows in the Varisai form). A leaf:
/// it alone observes the player, so the detail page does not
/// re-render per note — the Listen section's isolation rule,
/// applied to the scale card. The rows map 1:1 onto the
/// playback walk (arohana cells are walk indices
/// 0..<aro.count, avarohana cells follow), the same index the
/// piano highlight uses, so cell and piano light together.
private struct RagaSwaraRows: View {
    @ObservedObject var player: SequencePlayer
    let aro: [String]
    let ava: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("Arohana · ascending")
            SwaraGroupRow(labels: aro, currentIndex: player.currentIndex)
            rowLabel("Avarohana · descending")
                .padding(.top, 4)
            SwaraGroupRow(labels: ava, currentIndex: player.currentIndex - aro.count)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
