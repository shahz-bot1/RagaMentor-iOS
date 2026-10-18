import SwiftUI
import UniformTypeIdentifiers
import RagaCore
import AudioKit
import PersistenceKit
import SwaraEditor
import RagaBrowser
import DesignSystem

/// Compose Studio (web compose/index.html): the composition list
/// and, through the shared SwaraEditor, the editor. List order is
/// most-recently-updated first; a row's meta line is
/// "<raga> · <beats> beats · <tempo> bpm · <day mon>".
/// Playback goes through the app's ONE PhrasePlayer, so a
/// composition and a loop phrase never sound together; list playback
/// never loops (web rule), editor playback loops only while the
/// editor is open on that composition.
public struct CompositionListView: View {
    private let store: any CompositionStore
    private let library: any RagaLibrary
    @ObservedObject private var player: PhrasePlayer
    private let onPlayStart: () -> Void
    /// Cross-studio audio focus (P6): composition playback stops
    /// the other studios.
    @EnvironmentObject private var audioFocus: StudioAudioFocus

    @State private var compositions: [Composition] = []
    @State private var editorSession: EditorSession?
    @State private var openEditorID: String?
    @State private var showImporter = false
    @State private var importError: String?

    public init(store: any CompositionStore, library: any RagaLibrary,
                player: PhrasePlayer, onPlayStart: @escaping () -> Void) {
        self.store = store
        self.library = library
        self.player = player
        self.onPlayStart = onPlayStart
    }

    public var body: some View {
        List {
            if compositions.isEmpty {
                ContentUnavailableView {
                    Label("No compositions yet", systemImage: "music.note.list")
                } description: {
                    Text("Tap ＋ to write your first swara composition, or import one from a file.")
                }
            }
            ForEach(compositions) { comp in
                row(comp)
            }
        }
        .studioList()
        .navigationTitle("Compose Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let comp = store.createDefault()
                    refresh()
                    openEditor(comp)
                } label: {
                    Label("New composition", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .onAppear { refresh() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Import", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .fullScreenCover(item: $editorSession) { session in
            SwaraEditorView(
                model: session.model,
                title: name(of: session.id),
                compositionName: nameBinding(for: session.id),
                browseSheet: { model, dismiss in
                    AnyView(RagaBrowserView(
                        library: model.library, mode: .pick,
                        onPick: { raga in
                            model.applyBrowsedRaga(raga)
                            dismiss()
                        },
                        onCancel: dismiss))
                },
                deleteTitle: "Delete composition",
                deleteMessage: "Delete this composition?",
                onClose: {
                    editorSession = nil
                    openEditorID = nil
                    refresh()
                })
        }
    }

    // MARK: - Rows

    private func row(_ comp: Composition) -> some View {
        let key = "compose-list:\(comp.id)"
        let playing = player.isPlaying(contextKey: key)
        return HStack(spacing: 12) {
            Button {
                openEditor(comp)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comp.name.isEmpty ? "Untitled composition" : comp.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metaLine(comp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            StudioRoundButton(systemImage: playing ? "stop.fill" : "play.fill",
                              diameter: 38) {
                toggleListPlay(comp, key: key, playing: playing)
            }
        }
        .contextMenu {
            ShareLink(
                item: CompositionDocument(
                    data: CompositionFile.exportData(name: comp.name, phrase: comp.phrase)),
                preview: SharePreview(CompositionFile.fileSlug(for: comp.name))
            ) {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func metaLine(_ comp: Composition) -> String {
        let ragaName = comp.phrase.ragaId.flatMap { library.raga(id: $0)?.name }
            ?? "Chromatic"
        return "\(ragaName) · \(Swara.formatBeats(comp.phrase.totalBeats)) beats · "
            + "\(comp.phrase.tempo) bpm · \(Self.dayMon(comp.updatedAt))"
    }

    private static let dayMonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    private static func dayMon(_ date: Date) -> String {
        dayMonFormatter.string(from: date)
    }

    // MARK: - Playback

    /// Any composition playback (list row or editor): the host's
    /// hook plus the cross-studio focus stop.
    private func handlePlayStart() {
        onPlayStart()
        audioFocus.stopAll()
    }

    private func toggleListPlay(_ comp: Composition, key: String, playing: Bool) {
        if playing {
            player.stop()
        } else {
            handlePlayStart()
            var phrase = comp.phrase
            phrase.loop = false // list playback never loops (web rule)
            player.play(phrase: phrase, contextKey: key, contextValid: { true })
        }
    }

    // MARK: - Editor session

    private struct EditorSession: Identifiable {
        let id: String
        let model: SwaraEditorModel
    }

    private func openEditor(_ comp: Composition) {
        let id = comp.id
        let model = SwaraEditorModel(
            phrase: comp.phrase,
            hadSavedPhrase: true,
            contextKey: "compose-editor:\(id)",
            library: library,
            player: player,
            onSave: { phrase in store.save(phrase: phrase, for: id) },
            onDelete: { store.delete(id: id) },
            onSongRaga: { _ in },
            onPlayStart: handlePlayStart,
            contextValid: { openEditorID == id })
        openEditorID = id
        editorSession = EditorSession(id: id, model: model)
    }

    private func name(of id: String) -> String {
        compositions.first(where: { $0.id == id })?.name ?? "Composition"
    }

    private func nameBinding(for id: String) -> Binding<String> {
        Binding(
            get: { compositions.first(where: { $0.id == id })?.name ?? "" },
            set: { newName in
                store.rename(id: id, to: newName)
                refresh()
            })
    }

    // MARK: - Data

    private func refresh() {
        compositions = store.all()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = "That file isn't valid JSON."
            return
        }
        switch CompositionFile.parseImport(
            data: data, isKnownRaga: { library.raga(id: $0) != nil }) {
        case .success(let parsed):
            store.appendImported(name: parsed.name, phrase: parsed.phrase)
            refresh()
        case .failure(.invalidJSON):
            importError = "That file isn't valid JSON."
        case .failure(.invalidComposition):
            importError = "That doesn't look like a valid composition."
        }
    }
}

/// Export payload for the ShareLink (the composition envelope).
struct CompositionDocument: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}
