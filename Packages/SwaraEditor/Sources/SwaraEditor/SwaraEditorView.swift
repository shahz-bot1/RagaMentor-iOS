import SwiftUI
import AudioKit
import RagaCore
import DesignSystem
#if canImport(UIKit)
import UIKit
#endif

/// The full-screen swara editor (web swView): a Setup card (raga, Sa,
/// tempo, play, loop, JSON, delete) and a Phrase card (chip strip with
/// the total), or the raw-JSON card in JSON mode. Auto-saves on every
/// edit through the model; Done only closes; Cancel restores the
/// phrase as it was when the editor opened.
public struct SwaraEditorView: View {
    @ObservedObject public var model: SwaraEditorModel
    /// The player as a plain value: the chip strip observes it in a
    /// leaf (LivePhraseChipsView), so this screen no longer
    /// re-renders on every chip pulse.
    private let player: PhraseAdapter
    public var title: String
    public var onBrowseRaga: (() -> Void)?
    public var onClose: () -> Void
    /// Cancel hook: when a host passes one, the editor shows a
    /// Cancel button — the view restores the model
    /// (model.cancel()) and then calls this to dismiss. Hosts
    /// use it for anything the model cannot restore itself
    /// (Compose's live-renamed title). Nil hides the button.
    public var onCancel: (() -> Void)?
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
                onClose: @escaping () -> Void,
                onCancel: (() -> Void)? = nil) {
        self.model = model
        self.player = model.player
        self.title = title
        self.onBrowseRaga = onBrowseRaga
        self.compositionName = compositionName
        self.browseSheet = browseSheet
        self.deleteTitle = deleteTitle
        self.deleteMessage = deleteMessage
        self.onClose = onClose
        self.onCancel = onCancel
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
                ToolbarItem(placement: .cancellationAction) {
                    if let onCancel {
                        Button("Cancel") {
                            model.cancel()
                            onCancel()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.stopPlayback()
                        onClose()
                    }
                }
            }
        }
        // Any disappearance that bypasses the buttons (the host
        // dismissing the cover) must also silence the editor's
        // playback.
        .onDisappear { model.stopPlayback() }
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
            HStack {
                StudioSectionTitle("Phrase")
                Spacer()
                PhraseCardActions(model: model, player: player.player,
                                  deleteLabel: deleteTitle) {
                    confirmDelete = true
                }
            }
            if model.phrase.chips.isEmpty {
                Text("No swaras yet — tap ＋ to add the first chip.")
                    .foregroundStyle(.secondary)
            }
            LivePhraseChipsView(
                player: player.player,
                chips: model.phrase.chips,
                contextKey: model.contextKey,
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


/// The Phrase card header's actions (top right, like the
/// LoopLab Swaras card header): a round Play/Stop button, a Loop
/// toggle chip and the delete trash. It observes BOTH the model
/// and the player: the play state lives on the player (the setup
/// card never saw its changes, so Play never flipped to Stop),
/// and the loop state lives on the model's phrase. Moved here
/// from the Setup card at Shahzin's direction (v1.3.3).
struct PhraseCardActions: View {
    @ObservedObject var model: SwaraEditorModel
    @ObservedObject var player: SequencePlayer
    let deleteLabel: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudioRoundButton(
                systemImage: player.isPlaying(contextKey: model.contextKey)
                    ? "stop.fill" : "play.fill",
                diameter: 32) {
                model.togglePlay()
            }

            Button {
                model.setLoop(!model.phrase.loop)
            } label: {
                Text("Loop")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(model.phrase.loop ? Studio.accentSoft : Studio.panel2,
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        model.phrase.loop ? Studio.accent : Studio.border, lineWidth: 1))
                    .foregroundStyle(model.phrase.loop ? Studio.accent : Studio.text)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Color(red: 0.878, green: 0.322, blue: 0.322))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deleteLabel)
        }
    }
}
