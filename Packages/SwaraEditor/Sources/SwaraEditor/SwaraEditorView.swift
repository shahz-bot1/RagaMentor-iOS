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
    /// Compose hosts pass a name binding: the editor gains a Name
    /// row (web Compose renames via the editor title, live).
    public var compositionName: Binding<String>?
    /// The live RagaPicker hosts supply (P3): builds the full
    /// RagaBrowser in pick mode for this model, with a dismiss
    /// callback for when a pick lands or the user cancels. Nil
    /// keeps the interim browse sheet (hosts without a browser).
    public var browseSheet: ((SwaraEditorModel, @escaping () -> Void) -> AnyView)?
    /// Delete wording differs per host ("Delete swaras" in LoopLab,
    /// "Delete composition" in Compose).
    public var deleteTitle: String
    public var deleteMessage: String

    @State private var confirmDelete = false
    @State private var rawError: String?
    @State private var showRagaBrowser = false

    public init(model: SwaraEditorModel, title: String,
                onBrowseRaga: (() -> Void)? = nil,
                compositionName: Binding<String>? = nil,
                browseSheet: ((SwaraEditorModel, @escaping () -> Void) -> AnyView)? = nil,
                deleteTitle: String = "Delete swaras",
                deleteMessage: String = "Delete the swaras for this loop?",
                onClose: @escaping () -> Void) {
        self.model = model
        self.player = model.player
        self.title = title
        self.onBrowseRaga = onBrowseRaga
        self.compositionName = compositionName
        self.browseSheet = browseSheet
        self.deleteTitle = deleteTitle
        self.deleteMessage = deleteMessage
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
            .background(Studio.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.stopPlayback()
                        onClose()
                    }
                }
            }
        }
        .sheet(item: $model.picker) { _ in
            SwaraPickerSheet(model: model)
        }
        .sheet(isPresented: $showRagaBrowser) {
            if let browseSheet {
                browseSheet(model) { showRagaBrowser = false }
            } else {
                RagaBrowseSheet { raga in model.applyBrowsedRaga(raga) }
            }
        }
        .onChange(of: showRagaBrowser) { _, isShowing in
            // Opening the picker silences the editor's own playback
            // (the browser has its own tone engine).
            if isShowing { model.stopPlayback() }
        }
        .alert("JSON error", isPresented: Binding(
            get: { rawError != nil }, set: { if !$0 { rawError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rawError ?? "")
        }
        .confirmationDialog(deleteMessage,
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deleteTitle, role: .destructive) {
                model.deletePhrase()
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Setup card

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StudioSectionTitle("Setup")
                Spacer()
                Button(model.rawMode ? "♪ Phrase" : "{ } JSON") {
                    if model.rawMode { model.exitRawMode() } else { model.enterRawMode() }
                }
                .font(.callout)
            }

            if let compositionName {
                HStack {
                    Text("Name").foregroundStyle(.secondary)
                    Spacer()
                    TextField("Name", text: compositionName)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                }
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
                .tint(Studio.accent)
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
                .buttonStyle(StudioPrimaryButtonStyle())

                Button {
                    model.setLoop(!model.phrase.loop)
                } label: {
                    Text("Loop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .foregroundStyle(model.phrase.loop ? Studio.accent : Studio.text)
            }

            Button(deleteTitle, role: .destructive) { confirmDelete = true }
                .font(.callout)
        }
        .padding()
        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.border, lineWidth: 1))
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
            StudioSectionTitle("Phrase")
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
        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.border, lineWidth: 1))
    }

    // MARK: - Raw JSON card

    private var rawCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StudioSectionTitle("Phrase JSON")
                Spacer()
                Button("♪ Phrase") { model.exitRawMode() }.font(.callout)
            }
            TextEditor(text: $model.rawText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Studio.panel2))
            HStack {
                Button("Apply") {
                    rawError = model.applyRawJSON()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                Button("Cancel") { model.exitRawMode() }
                    .buttonStyle(StudioSecondaryButtonStyle())
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
                .buttonStyle(StudioSecondaryButtonStyle())
            }
        }
        .padding()
        .background(Studio.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.border, lineWidth: 1))
    }
}
