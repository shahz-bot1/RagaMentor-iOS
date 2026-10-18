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
    /// Jump to the A–B tab (the web's dashed ＋ New loop chip);
    /// only the fullscreen host can switch tabs.
    var onRequestAB: (() -> Void)? = nil

    /// The group currently drilled into (web's fsGroupView); nil =
    /// the top level.
    @State private var openGroupID: UUID?
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var editingGroup: LoopGroup?
    @State private var editorSession: EditorSession?

    var body: some View {
        // Content-sized (no own scrolling): the song detail's page
        // scrolls everything and pins the playback section.
        VStack(spacing: 14) {
                loopsChips
                if let loop = controller.selectedLoop {
                    SelectedLoopBar(song: song, loop: loop)
                }
                StudioCard {
                    SwarasSectionView(player: controller.phraseAdapter, song: song) { loop in
                        // Build the model ONCE, here in the action — never
                        // inside a presentation closure (v0.8.0 bug).
                        editorSession = EditorSession(loop: loop, model: editorModel(for: loop))
                    }
                    .environmentObject(controller)
                }
        }
        .padding(16)
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
                        sequencePlayer: model.player.player,
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
            player: controller.phraseAdapter,
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

    private enum ChipItem: Identifiable {
        case back
        case tree(TreeItem)
        case addLoops
        case newLoop
        case newGroup
        var id: String {
            switch self {
            case .back: return "back"
            case .tree(let item): return "tree-\(item.id.uuidString)"
            case .addLoops: return "addLoops"
            case .newLoop: return "newLoop"
            case .newGroup: return "newGroup"
            }
        }
    }

    /// Loops and groups as wrapping chips, flat on the page like
    /// the web (no card, no section title): group chips (colour
    /// dot, name, ▸, member count) drill in and arm the group's
    /// whole range; loop chips select; tapping the selected loop
    /// chip again deselects it. The dashed chips are the web's:
    /// ＋ New loop (fullscreen: jump to A–B) and ＋ New group.
    private var loopsChips: some View {
        var items: [ChipItem] = []
        if openGroup != nil { items.append(.back) }
        items += levelItems.map { .tree($0) }
        if openGroup != nil { items.append(.addLoops) }
        else {
            if onRequestAB != nil { items.append(.newLoop) }
            items.append(.newGroup)
        }
        return VStack(alignment: .leading, spacing: 8) {
            FlowStack(items: items, spacing: 8, rowSpacing: 8) { item in
                switch item {
                case .back:
                    chipButton(title: "‹ All", dashed: false) { openGroupID = nil }
                case .tree(.loop(let loop)):
                    loopChip(loop)
                case .tree(.group(let group)):
                    groupChip(group)
                case .addLoops:
                    chipButton(title: "＋ Add loops", dashed: true) {
                        if let openGroup { editingGroup = openGroup }
                    }
                case .newLoop:
                    chipButton(title: "＋ New loop", dashed: true) {
                        onRequestAB?()
                    }
                case .newGroup:
                    chipButton(title: "＋ New group", dashed: true) {
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

    private func loopChip(_ loop: LoopRegion) -> some View {
        let selected = controller.selectedLoopID == loop.id
        return Button {
            if selected { controller.clearLoopSelection() }
            else { controller.selectLoop(loop, context: modelContext) }
        } label: {
            HStack(spacing: 7) {
                Text(loop.name)
                if controller.hasPhrase(loop) {
                    Text("♪").font(.caption)
                }
            }
            .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Studio.accent : Studio.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.border, lineWidth: selected ? 0 : 1))
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
            HStack(spacing: 7) {
                Circle().fill(Color(hex: group.colorHex)).frame(width: 9, height: 9)
                Text(group.name)
                Text("▸")
                    .font(.system(size: 11))
                    .foregroundStyle(armed ? .white.opacity(0.65) : .secondary)
                Text("\(group.memberIDs.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(armed ? .white.opacity(0.65) : .secondary)
            }
            .font(.system(size: 13.5, weight: armed ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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

    private func chipButton(title: String, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(dashed ? Color.clear : Studio.panel2, in: Capsule())
                .overlay(Capsule().strokeBorder(Studio.border,
                                                style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : [])))
                .foregroundStyle(dashed ? .secondary : Studio.text)
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

/// The selected loop's bar (web #fsSelRow + #fsNote): the name
/// field with a delete button, and the note line under it. Edge
/// editing lives on the A–B tab, as on web.
struct SelectedLoopBar: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    /// Jump to the A–B tab (the web's dashed ＋ New loop chip);
    /// only the fullscreen host can switch tabs.
    var onRequestAB: (() -> Void)? = nil
    let loop: LoopRegion
    @State private var nameDraft = ""
    @State private var noteDraft = ""

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("Loop name", text: $nameDraft)
                        .font(.body.weight(.medium))
                        .onSubmit { controller.renameLoop(loop, to: nameDraft, context: modelContext) }
                    Button(role: .destructive) {
                        controller.deleteLoop(loop, context: modelContext)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                TextField("Note (key, swara cues…)", text: $noteDraft)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .onSubmit { controller.setLoopNote(loop, to: noteDraft, context: modelContext) }
            }
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
}

/// Group membership checklist (PLAN §3 decision 12): pick exactly which
/// loops (and, for top-level groups, which sub-groups) belong.
struct GroupEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    /// Jump to the A–B tab (the web's dashed ＋ New loop chip);
    /// only the fullscreen host can switch tabs.
    var onRequestAB: (() -> Void)? = nil
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
