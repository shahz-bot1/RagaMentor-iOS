import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RagaCore
import AudioKit
import PersistenceKit
import SwaraEditor
import RagaBrowser
import DesignSystem

// Loops tab content (PLAN §10): loop rows with range + note, groups with
// derived ranges, tap to select-and-play. Editing lives in the detail
// section for the selected loop. M5 re-hosts this in the fullscreen view.

struct LoopsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    /// Cross-studio audio focus (P6): phrase playback stops the
    /// other studios.
    @EnvironmentObject private var audioFocus: StudioAudioFocus
    let song: Song

    /// The group currently drilled into (web's fsGroupView); nil =
    /// the top level.
    @State private var openGroupID: UUID?
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var editingGroup: LoopGroup?
    @State private var editorSession: EditorSession?
    @State private var showImporter = false
    @State private var confirmImport = false
    @State private var pendingImportData: Data?
    @State private var importFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                loopsCard
                if let loop = controller.selectedLoop {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 8) {
                            StudioSectionTitle("Selected loop")
                            LoopEditorView(song: song, loop: loop)
                        }
                    }
                }
                StudioCard {
                    VStack(alignment: .leading, spacing: 8) {
                        StudioSectionTitle("Swaras")
                        SwarasSectionView(player: controller.phrasePlayer, song: song) { loop in
                            // Build the model ONCE, here in the action — never
                            // inside a presentation closure (v0.8.0 bug).
                            editorSession = EditorSession(loop: loop, model: editorModel(for: loop))
                        }
                        .environmentObject(controller)
                    }
                }
                backupCard
            }
            .padding(16)
        }
        .background(Studio.bg.ignoresSafeArea())
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    pendingImportData = data
                    confirmImport = true
                } else {
                    importFailed = true
                }
            }
        }
        .confirmationDialog("Replace all loops for this song with the imported set?",
                            isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Replace loops", role: .destructive) {
                if let data = pendingImportData,
                   !controller.importBackup(data: data, context: modelContext) {
                    importFailed = true
                }
                pendingImportData = nil
            }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        }
        .alert("Import failed", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That file is not a valid RagaMentor loops backup.")
        }
        .navigationTitle("Loops")
        .navigationBarTitleDisplayMode(.inline)
        .alert("New group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { controller.createGroup(name: newGroupName, context: modelContext) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editingGroup) { group in
            GroupEditorView(song: song, group: group)
                .environmentObject(controller)
        }
        .navigationDestination(item: $editorSession) { session in
            SwaraEditorView(
                model: session.model,
                title: session.loop.name,
                browseSheet: { model, dismiss in
                    AnyView(RagaBrowserView(
                        library: model.library, mode: .pick,
                        onPick: { raga in
                            model.applyBrowsedRaga(raga)
                            dismiss()
                        },
                        onCancel: dismiss))
                },
                onClose: { editorSession = nil })
        }
    }

    /// One editor presentation: the loop plus its model, created once
    /// when the user taps Add/Edit and held in @State for the whole
    /// presentation, so the editor's model identity is stable.
    /// Hashable by loop id for the navigation destination.
    ///
    /// The editor is PUSHED, not covered: as a fullScreenCover it
    /// oscillated (open, close, open, close) on device — the cover
    /// lived deep inside the fullscreen player's tab switch under a
    /// 20 Hz position publisher, and the modal layer kept tearing
    /// down. A pushed destination is owned by the navigation stack
    /// and does not oscillate. (Compose keeps its cover: its host is
    /// a calm tab-root list, where the cover is stable.)
    private struct EditorSession: Identifiable, Hashable {
        let loop: LoopRegion
        let model: SwaraEditorModel
        var id: UUID { loop.id }
        static func == (lhs: EditorSession, rhs: EditorSession) -> Bool {
            lhs.loop.id == rhs.loop.id
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(loop.id)
        }
    }

    /// Build the swara editor's model for a loop, wired to the
    /// controller's phrase storage and interlocks.
    private func editorModel(for loop: LoopRegion) -> SwaraEditorModel {
        let existing = controller.phrase(for: loop)
        return SwaraEditorModel(
            phrase: existing ?? controller.defaultPhrase(for: song),
            hadSavedPhrase: existing != nil,
            contextKey: controller.editorKey(for: loop),
            library: controller.ragaLibrary,
            player: controller.phrasePlayer,
            onSave: { [weak controller] phrase in
                controller?.savePhrase(phrase, for: loop, context: modelContext)
            },
            onDelete: { [weak controller] in
                controller?.clearPhrase(for: loop, context: modelContext)
            },
            onSongRaga: { [weak controller] id in
                controller?.noteSongRaga(id, context: modelContext)
            },
            onPlayStart: { [weak controller] in
                controller?.pause()
                audioFocus.stopAll()
            })
    }

    // MARK: - Loops chip collection (web #fsChips)

    private var openGroup: LoopGroup? {
        openGroupID.flatMap { id in song.groups.first { $0.id == id } }
    }

    /// Loops and groups as wrapping chips, the web's model: group
    /// chips (colour dot, name, member count, chevron) drill in and
    /// arm the group's whole range; loop chips select; tapping the
    /// selected loop chip again deselects it.
    private var loopsCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle("Loops")
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    if openGroup != nil {
                        chipButton(title: "‹ All", filled: false) { openGroupID = nil }
                    }
                    ForEach(levelItems, id: \.id) { item in
                        switch item {
                        case .loop(let loop):
                            loopChip(loop)
                        case .group(let group):
                            groupChip(group)
                        }
                    }
                    if let openGroup {
                        chipButton(title: "＋ Add loops", filled: false) {
                            editingGroup = openGroup
                        }
                    } else {
                        chipButton(title: "＋ New group", filled: false) {
                            newGroupName = ""
                            showNewGroup = true
                        }
                    }
                }
                if song.loops.isEmpty {
                    Text("No loops yet. Use Set A and Set B on the player to mark a section.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let group = openGroup {
                    Text(memberSummary(of: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loopChip(_ loop: LoopRegion) -> some View {
        let selected = controller.selectedLoopID == loop.id
        return Button {
            if selected { controller.clearLoopSelection() }
            else { controller.selectLoop(loop, context: modelContext) }
        } label: {
            HStack(spacing: 5) {
                Text(loop.name)
                if controller.hasPhrase(loop) {
                    Text("♪").font(.caption)
                }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Studio.accent : Studio.panel2, in: Capsule())
            .foregroundStyle(selected ? .white : Studio.text)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                controller.deleteLoop(loop, context: modelContext)
            } label: { Label("Delete loop", systemImage: "trash") }
        }
    }

    private func groupChip(_ group: LoopGroup) -> some View {
        let armed = controller.selectedGroupID == group.id
        return Button {
            openGroupID = group.id
            controller.selectGroup(group, context: modelContext)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: group.colorHex)).frame(width: 9, height: 9)
                Text(group.name)
                Text("\(group.memberIDs.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(armed ? .white.opacity(0.8) : .secondary)
                Text("▸").font(.caption).foregroundStyle(armed ? .white.opacity(0.8) : .secondary)
            }
            .font(.subheadline.weight(armed ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(armed ? Studio.accent : Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.border, lineWidth: armed ? 0 : 1))
            .foregroundStyle(armed ? .white : Studio.text)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingGroup = group
            } label: { Label("Edit group…", systemImage: "pencil") }
        }
    }

    private func chipButton(title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Studio.panel2, in: Capsule())
                .overlay(Capsule().strokeBorder(Studio.border, lineWidth: 1))
                .foregroundStyle(Studio.text)
        }
        .buttonStyle(.plain)
    }

    private func memberSummary(of group: LoopGroup) -> String {
        let loops = GroupOps.descendantLoopIDs(of: group.id,
                                               groups: controller.groupData(song),
                                               loopIDs: Set(song.loops.map(\.id)))
        if let range = LoopsView.derivedRange(of: group, song: song) {
            return "\(loops.count) item\(loops.count == 1 ? "" : "s") · \(LibraryView.formatDuration(range.start)) – \(LibraryView.formatDuration(range.end))"
        }
        return "\(loops.count) items"
    }

    private var backupCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                StudioSectionTitle("Backup")
                if let data = controller.backupJSON() {
                    ShareLink(item: BackupDocument(data: data),
                              preview: SharePreview("\(song.title) loops")) {
                        Label("Export loops…", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import loops…", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    // MARK: Tree construction

    private enum TreeItem {
        case loop(LoopRegion)
        case group(LoopGroup)
        var id: UUID {
            switch self {
            case .loop(let l): return l.id
            case .group(let g): return g.id
            }
        }
    }

    private func start(of item: TreeItem) -> Double {
        switch item {
        case .loop(let loop): return loop.start
        case .group(let group): return LoopsView.derivedRange(of: group, song: song)?.start ?? .greatestFiniteMagnitude
        }
    }

    /// Items at the current drill level.
    private var levelItems: [TreeItem] {
        if let openGroup { return memberItems(of: openGroup) }
        return topLevelItems
    }

    /// Ungrouped loops + top-level groups, interleaved by start time.
    private var topLevelItems: [TreeItem] {
        let parent = GroupOps.parentMap(groups: controller.groupData(song))
        var items: [TreeItem] = []
        for group in song.groups where parent[group.id] == nil {
            items.append(.group(group))
        }
        let groupedIDs = Set(parent.keys)
        for loop in song.loops where !groupedIDs.contains(loop.id) {
            items.append(.loop(loop))
        }
        return items.sorted { (start(of: $0), $0.id.uuidString) < (start(of: $1), $1.id.uuidString) }
    }

    private func memberItems(of group: LoopGroup) -> [TreeItem] {
        group.memberIDs.compactMap { id -> TreeItem? in
            if let loop = song.loops.first(where: { $0.id == id }) { return .loop(loop) }
            if let sub = song.groups.first(where: { $0.id == id }) { return .group(sub) }
            return nil
        }
        .sorted { (start(of: $0), $0.id.uuidString) < (start(of: $1), $1.id.uuidString) }
    }

    static func derivedRange(of group: LoopGroup, song: Song) -> (start: Double, end: Double)? {
        let children = Dictionary(uniqueKeysWithValues: song.groups.map { ($0.id, $0.memberIDs) })
        let spans = Dictionary(uniqueKeysWithValues: song.loops.map {
            ($0.id, LoopSpan(id: $0.id, start: $0.start, end: $0.end))
        })
        return GroupLogic.derivedRange(groupID: group.id, children: children, spans: spans)
    }
}

/// JSON payload for the loops-backup ShareLink.
struct BackupDocument: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}

/// Editor for the selected loop: rename, note, 0.1 s nudges, split, delete.
struct LoopEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    let loop: LoopRegion
    @State private var nameDraft: String = ""
    @State private var noteDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Loop name", text: $nameDraft)
                .onSubmit { controller.renameLoop(loop, to: nameDraft, context: modelContext) }
            TextField("Note (key, swara cues…)", text: $noteDraft)
                .onSubmit { controller.setLoopNote(loop, to: noteDraft, context: modelContext) }

            HStack {
                Text("A \(precise(loop.start))")
                Spacer()
                Button("−0.1") { controller.nudgeLoop(loop, edge: .start, by: -0.1, context: modelContext) }
                    .buttonStyle(.bordered)
                Button("+0.1") { controller.nudgeLoop(loop, edge: .start, by: 0.1, context: modelContext) }
                    .buttonStyle(.bordered)
            }
            HStack {
                Text("B \(precise(loop.end))")
                Spacer()
                Button("−0.1") { controller.nudgeLoop(loop, edge: .end, by: -0.1, context: modelContext) }
                    .buttonStyle(.bordered)
                Button("+0.1") { controller.nudgeLoop(loop, edge: .end, by: 0.1, context: modelContext) }
                    .buttonStyle(.bordered)
            }

            HStack {
                Button {
                    controller.splitLoop(loop, context: modelContext)
                } label: { Label("Split at playhead", systemImage: "scissors") }
                .disabled(!LoopRules.canSplit(loopStart: loop.start, loopEnd: loop.end, at: controller.position))
                Spacer()
                Button(role: .destructive) {
                    controller.deleteLoop(loop, context: modelContext)
                } label: { Label("Delete", systemImage: "trash") }
            }
            .font(.subheadline)
        }
        .onAppear {
            nameDraft = loop.name
            noteDraft = loop.note
        }
        .onChange(of: loop.id) {
            nameDraft = loop.name
            noteDraft = loop.note
        }
    }

    private func precise(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}

/// Group membership checklist (PLAN §3 decision 12): pick exactly which
/// loops (and, for top-level groups, which sub-groups) belong.
struct GroupEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    let group: LoopGroup

    @State private var nameDraft: String = ""
    @State private var checked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Group name", text: $nameDraft)
                }
                Section("Members") {
                    ForEach(candidates, id: \.id) { candidate in
                        Button {
                            if checked.contains(candidate.id) { checked.remove(candidate.id) }
                            else { checked.insert(candidate.id) }
                        } label: {
                            HStack {
                                Image(systemName: checked.contains(candidate.id) ? "checkmark.square.fill" : "square")
                                Text(candidate.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(candidate.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if candidates.isEmpty {
                        Text("Nothing available to add.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        controller.deleteGroup(group, context: modelContext)
                        dismiss()
                    } label: { Label("Delete group (children move up)", systemImage: "trash") }
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        controller.renameGroup(group, to: nameDraft, context: modelContext)
                        // Preserve existing members that are not checklist
                        // candidates (e.g. sub-groups of a sub-group view);
                        // only candidate membership is edited here.
                        let candidateIDs = Set(candidates.map(\.id))
                        let preserved = group.memberIDs.filter { !candidateIDs.contains($0) }
                        let chosen = candidates.map(\.id).filter { checked.contains($0) }
                        controller.setGroupMembers(group,
                                                   memberIDs: preserved + chosen,
                                                   context: modelContext)
                        dismiss()
                    }
                }
            }
            .onAppear {
                nameDraft = group.name
                checked = Set(group.memberIDs)
            }
        }
    }

    private struct Candidate: Identifiable {
        let id: UUID
        let label: String
        let detail: String
    }

    /// Candidates: every loop; plus groups only when this group is
    /// top-level and the candidate is a top-level, loop-only group
    /// (the 2-level cap, PLAN §3 decision 12).
    private var candidates: [Candidate] {
        let parent = GroupOps.parentMap(groups: controller.groupData(song))
        let isTopLevel = parent[group.id] == nil
        var out: [Candidate] = song.loops
            .sorted { $0.start < $1.start }
            .map { Candidate(id: $0.id, label: $0.name,
                             detail: "\(LibraryView.formatDuration($0.start)) – \(LibraryView.formatDuration($0.end))") }
        if isTopLevel {
            let groupIDs = Set(song.groups.map(\.id))
            // Exclude this group's own descendant groups (cycle guard).
            var descendants = Set<UUID>()
            func collect(_ gid: UUID) {
                for m in song.groups.first(where: { $0.id == gid })?.memberIDs ?? [] where groupIDs.contains(m) {
                    if descendants.insert(m).inserted { collect(m) }
                }
            }
            collect(group.id)
            for other in song.groups where other.id != group.id && !descendants.contains(other.id) {
                // Only loop-only groups may become sub-groups (cap = 2).
                let holdsGroup = other.memberIDs.contains { groupIDs.contains($0) }
                if !holdsGroup {
                    out.append(Candidate(id: other.id, label: "▸ \(other.name)", detail: "group"))
                }
            }
        }
        return out
    }
}

extension Color {
    /// A Color from a "#rrggbb" hex string (group colours).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x5B9DFF
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
