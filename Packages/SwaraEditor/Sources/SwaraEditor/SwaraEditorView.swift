import SwiftUI
import RagaCore
import DesignSystem
#if canImport(UIKit)
import UIKit
#endif

/// The full-screen swara editor (web swView): a Setup card (raga, Sa,
/// tempo, play, loop, JSON, delete) and a Phrase card (chip strip with
/// the total), or the raw-JSON card in JSON mode. Auto-saves on every
/// edit through the model; Done only closes.
public struct SwaraEditorView: View {
    @ObservedObject public var model: SwaraEditorModel
    @ObservedObject private var player: PhrasePlayer
    public var title: String
    public var onBrowseRaga: (() -> Void)?
    public var onClose: () -> Void

    @State private var confirmDelete = false
    @State private var rawError: String?
    @State private var showRagaBrowser = false
    @Environment(\.dismiss) private var dismiss

    public init(model: SwaraEditorModel, title: String,
                onBrowseRaga: (() -> Void)? = nil,
                onClose: @escaping () -> Void) {
        self.model = model
        self.player = model.player
        self.title = title
        self.onBrowseRaga = onBrowseRaga
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if model.rawMode {
                        rawCard
                    } else {
                        setupCard
                        phraseCard
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.stopPlayback()
                        onClose()
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $model.picker) { _ in
            SwaraPickerSheet(model: model)
        }
        .sheet(isPresented: $showRagaBrowser) {
            RagaBrowseSheet { raga in model.applyBrowsedRaga(raga) }
        }
        .alert("JSON error", isPresented: Binding(
            get: { rawError != nil }, set: { if !$0 { rawError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rawError ?? "")
        }
        .confirmationDialog("Delete the swaras for this loop?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete swaras", role: .destructive) {
                model.deletePhrase()
                onClose()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Setup card

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Setup").font(.headline)
                Spacer()
                Button(model.rawMode ? "♪ Phrase" : "{ } JSON") {
                    if model.rawMode { model.exitRawMode() } else { model.enterRawMode() }
                }
                .font(.callout)
            }

            HStack {
                Text("Raga").foregroundStyle(.secondary)
                Spacer()
                ragaMenu
            }

            HStack {
                Text("Sa").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(0..<12, id: \.self) { i in
                        Button("Sa = \(Swara.saNames[i])") { model.setSaOffset(i) }
                    }
                } label: {
                    Text("Sa = \(Swara.saNames[model.phrase.saOffset])")
                }
            }

            HStack {
                Text("Tempo").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(model.phrase.tempo) },
                    set: { model.setTempo(Int($0.rounded())) }),
                       in: 30...120, step: 1)
                Text("\(model.phrase.tempo) bpm")
                    .font(.callout.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Text(model.isPlaying || player.isPlaying(contextKey: model.contextKey)
                         ? "■ Stop" : "▶ Play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPlaying ? .red : DesignTokens.accent)

                Button {
                    model.setLoop(!model.phrase.loop)
                } label: {
                    Text("Loop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(model.phrase.loop ? DesignTokens.accent : .secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(model.phrase.loop ? DesignTokens.accent : .clear, lineWidth: 1)
                )
            }

            Button("Delete swaras", role: .destructive) { confirmDelete = true }
                .font(.callout)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private var ragaMenu: some View {
        Menu {
            Button("Chromatic (no raga)") { model.setRaga(id: nil) }
            let groups = model.library.dropdownGroups(currentId: model.phrase.ragaId)
            if !groups.recents.isEmpty {
                Section("Recents") {
                    ForEach(groups.recents, id: \.id) { raga in
                        Button(raga.name) { model.setRaga(id: raga.id) }
                    }
                }
            }
            if !groups.favourites.isEmpty {
                Section("Favourites") {
                    ForEach(groups.favourites, id: \.id) { raga in
                        Button(raga.name) { model.setRaga(id: raga.id) }
                    }
                }
            }
            // The full raga list is ALWAYS reachable (parity plan §6
            // P1): the host's RagaBrowser route from P3, or the interim
            // in-editor browse sheet until then. (v0.8.0 build 11 hid
            // the entry entirely when no host route was passed, which
            // left the dropdown with only Chromatic/Recents/Favourites
            // and no way to browse the catalog — user report.)
            if let onBrowseRaga {
                Button("RagaBrowser ›") { onBrowseRaga() }
            } else {
                Button("RagaBrowser ›") { showRagaBrowser = true }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.ragaName)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
    }

    // MARK: - Phrase card

    private var phraseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phrase").font(.headline)
            if model.phrase.chips.isEmpty {
                Text("No swaras yet — tap ＋ to add the first chip.")
                    .foregroundStyle(.secondary)
            }
            PhraseChipsView(
                chips: model.phrase.chips,
                currentIndex: player.isPlaying(contextKey: model.contextKey)
                    ? player.currentChipIndex : -1,
                onTapChip: { model.openEditPicker(index: $0) },
                onTapAdd: { model.openAppendPicker() })
            HStack {
                Spacer()
                Text(Swara.formatBeats(model.phrase.totalBeats))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Raw JSON card

    private var rawCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Phrase JSON").font(.headline)
                Spacer()
                Button("♪ Phrase") { model.exitRawMode() }.font(.callout)
            }
            TextEditor(text: $model.rawText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.10)))
            HStack {
                Button("Apply") {
                    rawError = model.applyRawJSON()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.accent)
                Button("Cancel") { model.exitRawMode() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(model.copyConfirmed ? "Copied ✓" : "Copy all") {
#if canImport(UIKit)
                    UIPasteboard.general.string = model.rawText
#endif
                    model.copyConfirmed = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        model.copyConfirmed = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }
}
