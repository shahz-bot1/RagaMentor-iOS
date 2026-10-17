import SwiftUI
import SwiftData

// Loops tab content (PLAN §10): loop rows with range + note, groups with
// derived ranges, tap to select-and-play. Editing lives in the detail
// section for the selected loop. M5 re-hosts this in the fullscreen view.

struct LoopsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song

    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var editingGroup: LoopGroup?

    var body: some View {
        List {
            if let loop = controller.selectedLoop {
                Section("Selected loop") {
                    LoopEditorView(song: song, loop: loop)
                }
            }

            Section {
                ForEach(topLevelItems, id: \.id) { item in
                    itemView(item, depth: 0)
                }
                if song.loops.isEmpty {
                    Text("No loops yet. Use Set A and Set B on the player to mark a section.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Loops")
            }

            Section {
                Button {
                    newGroupName = ""
                    showNewGroup = true
                } label: {
                    Label("New group", systemImage: "folder.badge.plus")
                }
            }
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
        var start: Double {
            switch self {
            case .loop(let l): return l.start
            case .group(let g): return LoopsView.derivedRange(of: g, song: song)?.start ?? .greatestFiniteMagnitude
            }
        }
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
        return items.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    private func memberItems(of group: LoopGroup) -> [TreeItem] {
        group.memberIDs.compactMap { id -> TreeItem? in
            if let loop = song.loops.first(where: { $0.id == id }) { return .loop(loop) }
            if let sub = song.groups.first(where: { $0.id == id }) { return .group(sub) }
            return nil
        }
    }

    @ViewBuilder
    private func itemView(_ item: TreeItem, depth: Int) -> some View {
        switch item {
        case .loop(let loop):
            LoopRowView(song: song, loop: loop)
                .padding(.leading, CGFloat(depth) * 16)
        case .group(let group):
            GroupHeaderView(song: song, group: group) { editingGroup = group }
            ForEach(memberItems(of: group), id: \.id) { member in
                itemView(member, depth: depth + 1)
            }
        }
    }

    static func derivedRange(of group: LoopGroup, song: Song) -> (start: Double, end: Double)? {
        let children = Dictionary(uniqueKeysWithValues: song.groups.map { ($0.id, $0.memberIDs) })
        let spans = Dictionary(uniqueKeysWithValues: song.loops.map {
            ($0.id, LoopSpan(id: $0.id, start: $0.start, end: $0.end))
        })
        return GroupLogic.derivedRange(groupID: group.id, children: children, spans: spans)
    }
}

struct LoopRowView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    let loop: LoopRegion

    var body: some View {
        Button {
            controller.selectLoop(loop, context: modelContext)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loop.name)
                        .foregroundStyle(.primary)
                    Text("\(fmt(loop.start)) – \(fmt(loop.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !loop.note.isEmpty {
                        Text(loop.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if controller.selectedLoopID == loop.id {
                    Image(systemName: controller.loopOn ? "repeat.circle.fill" : "checkmark.circle")
                        .foregroundStyle(.tint)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                controller.deleteLoop(loop, context: modelContext)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func fmt(_ t: Double) -> String { LibraryView.formatDuration(t) }
}

struct GroupHeaderView: View {
    @EnvironmentObject private var controller: PlaybackController
    let song: Song
    let group: LoopGroup
    var onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline).bold()
                        .foregroundStyle(.primary)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let loops = GroupOps.descendantLoopIDs(of: group.id,
                                               groups: controller.groupData(song),
                                               loopIDs: Set(song.loops.map(\.id)))
        if let range = LoopsView.derivedRange(of: group, song: song) {
            return "\(loops.count) item\(loops.count == 1 ? "" : "s") · \(LibraryView.formatDuration(range.start)) – \(LibraryView.formatDuration(range.end))"
        }
        return "\(loops.count) items"
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
