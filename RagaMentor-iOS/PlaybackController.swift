import Foundation
import SwiftData
import Combine
#if canImport(UIKit)
import UIKit
#endif

// Single source of truth for playback state (PLAN §5): transport,
// speed, current song, playhead position (~20 Hz publish).

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published var speed: Float = 1.0 {
        didSet { engine.rate = speed }
    }
    @Published var importError: String?
    @Published var playbackError: String?

    /// Speed presets, slowest first (PLAN §2/§10).
    static let speedPresets: [Float] = [0.25, 0.5, 0.75, 1.0]

    // MARK: Loop state (M3, PLAN §10)

    /// The loop the chips/A–B actions refer to.
    @Published private(set) var selectedLoopID: UUID?
    /// Whether the selected loop is armed in the engine.
    @Published private(set) var loopOn = false
    /// Pending A / B marks while creating a loop from the A–B controls.
    @Published private(set) var pendingA: Double?
    @Published private(set) var pendingB: Double?

    var selectedLoop: LoopRegion? {
        guard let song = currentSong, let id = selectedLoopID else { return nil }
        return song.loops.first { $0.id == id }
    }

    let engine = AudioEngine()
    private var positionTimer: Timer?

    init() {
        engine.rate = speed
    }

    // MARK: - Song selection

    /// Open a song: load its file and restore the saved position (PLAN §11).
    func open(_ song: Song) {
        guard let url = song.fileURL else {
            playbackError = "The audio file for this song is missing."
            return
        }
        do {
            try engine.load(url: url)
        } catch {
            playbackError = "This song could not be loaded."
            return
        }
        currentSong = song
        position = TimeMath.clamp(song.lastPosition, min: 0, max: song.duration)
        engine.stop()
        isPlaying = false
        // Restore the previous selection (PLAN §11). The loop is armed in
        // the engine; playback enters it at the restored position.
        pendingA = nil
        pendingB = nil
        if let lastID = song.lastLoopID, let loop = song.loops.first(where: { $0.id == lastID }) {
            selectedLoopID = loop.id
            loopOn = true
            engine.setLoop(start: loop.start, end: loop.end)
        } else {
            selectedLoopID = nil
            loopOn = false
            engine.setLoop(start: nil, end: nil)
        }
        startPositionTimer()
    }

    func closeSong() {
        savePosition()
        engine.stop()
        engine.setLoop(start: nil, end: nil)
        isPlaying = false
        currentSong = nil
        position = 0
        selectedLoopID = nil
        loopOn = false
        pendingA = nil
        pendingB = nil
        stopPositionTimer()
    }

    // MARK: - Transport

    func togglePlay() {
        guard currentSong != nil else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            savePosition()
        } else {
            if engine.loadedFile == nil, let song = currentSong { open(song) }
            if position >= (currentSong?.duration ?? 0) - 0.05 { position = 0 }
            engine.play(from: position)
            // play(from:) restarts the schedule at `position`; if the engine
            // was merely paused mid-schedule this is still correct because
            // the schedule restarts from the published position.
            isPlaying = true
        }
    }

    func play() {
        if !isPlaying { togglePlay() }
    }

    func pause() {
        if isPlaying { togglePlay() }
    }

    func seek(to seconds: Double) {
        guard let song = currentSong else { return }
        position = TimeMath.clamp(seconds, min: 0, max: song.duration)
        engine.seek(to: position)
        if !isPlaying { engine.pause() }
        savePosition()
    }

    func skip(by delta: Double) {
        seek(to: position + delta)
    }

    // MARK: - Library actions

    /// Import picked files; returns the last imported/opened song so the
    /// caller can select it. Dedupe is handled in ImportService.
    @discardableResult
    func importFiles(_ urls: [URL], context: ModelContext) -> Song? {
        var last: Song?
        for url in urls {
            do {
                last = try ImportService.importSong(from: url, context: context)
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? "Import failed."
            }
        }
        return last
    }

    /// Delete a song: stop playback if it is current, remove the stored
    /// file, delete the record (loops cascade, PLAN §6).
    func deleteSong(_ song: Song, context: ModelContext) {
        if currentSong?.id == song.id { closeSong() }
        ImportService.removeStoredFile(for: song)
        context.delete(song)
        try? context.save()
    }

    // MARK: - Loop creation (A–B marks)

    func setA() { pendingA = position; completeLoopIfReady() }
    func setB() { pendingB = position; completeLoopIfReady() }
    func clearPendingMarks() { pendingA = nil; pendingB = nil }

    private func completeLoopIfReady() {
        guard let a = pendingA, let b = pendingB else { return }
        pendingA = nil
        pendingB = nil
        guard let context = modelContext else { return }
        createLoop(start: a, end: b, context: context)
    }

    /// ModelContext handed in by the view layer for loop/group writes
    /// (import/delete already receive it per call; creation from the
    /// transport controls needs it stored).
    var modelContext: ModelContext?

    /// Create a loop from two marks: normalises (auto-swap when B <= A,
    /// with a haptic — PLAN §12), names it, selects and arms it.
    @discardableResult
    func createLoop(start rawStart: Double, end rawEnd: Double, context: ModelContext) -> LoopRegion? {
        guard let song = currentSong,
              let range = LoopRules.normalize(start: rawStart, end: rawEnd, duration: song.duration) else { return nil }
        if rawEnd < rawStart { haptic() }
        let loop = LoopRegion(name: nextLoopName(song: song),
                              start: range.start,
                              end: range.end,
                              sortOrder: song.loops.count,
                              song: song)
        song.loops.append(loop)
        resortLoops(song)
        selectLoop(loop, context: context, autoplay: isPlaying)
        try? context.save()
        return loop
    }

    private func nextLoopName(song: Song) -> String {
        let names = Set(song.loops.map(\.name))
        var n = 1
        while names.contains("Loop \(n)") { n += 1 }
        return "Loop \(n)"
    }

    // MARK: - Loop selection & editing

    /// Select a loop: the playhead jumps to A and the loop is armed
    /// (PLAN §10; acceptance: tap a chip → jump to A and loop).
    func selectLoop(_ loop: LoopRegion, context: ModelContext, autoplay: Bool = true) {
        guard let song = currentSong else { return }
        selectedLoopID = loop.id
        song.lastLoopID = loop.id
        loopOn = true
        engine.setLoop(start: loop.start, end: loop.end)
        position = loop.start
        if autoplay {
            engine.play(from: loop.start)
            isPlaying = true
        } else {
            engine.seek(to: loop.start)
            engine.pause()
        }
        try? context.save()
    }

    /// Arm/disarm looping of the selected loop without changing selection.
    func toggleLoopOn() {
        guard let loop = selectedLoop else { return }
        loopOn.toggle()
        if loopOn {
            engine.setLoop(start: loop.start, end: loop.end)
            if isPlaying { engine.play(from: position) }
        } else {
            engine.setLoop(start: nil, end: nil)
            if isPlaying { engine.play(from: position) }
        }
    }

    func renameLoop(_ loop: LoopRegion, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loop.name = trimmed
        try? context.save()
    }

    func setLoopNote(_ loop: LoopRegion, to note: String, context: ModelContext) {
        loop.note = note
        try? context.save()
    }

    /// 0.1 s nudge steppers (PLAN §10): adjusts one edge, re-normalised.
    func nudgeLoop(_ loop: LoopRegion, edge: Edge, by delta: Double, context: ModelContext) {
        guard let song = currentSong else { return }
        let newStart = edge == .start ? loop.start + delta : loop.start
        let newEnd = edge == .end ? loop.end + delta : loop.end
        guard let range = LoopRules.normalize(start: newStart, end: newEnd, duration: song.duration) else { return }
        loop.start = range.start
        loop.end = range.end
        resortLoops(song)
        if selectedLoopID == loop.id && loopOn {
            engine.setLoop(start: loop.start, end: loop.end)
        }
        try? context.save()
    }

    enum Edge { case start, end }

    /// Split the loop at the current playhead (PLAN §10 A–B rules).
    func splitLoop(_ loop: LoopRegion, context: ModelContext) {
        guard let song = currentSong,
              LoopRules.canSplit(loopStart: loop.start, loopEnd: loop.end, at: position) else { return }
        let originalEnd = loop.end
        loop.end = position
        let second = LoopRegion(name: LoopRules.splitSecondName(originalName: loop.name,
                                                                 existingNames: song.loops.map(\.name)),
                                start: position,
                                end: originalEnd,
                                sortOrder: loop.sortOrder + 1,
                                song: song)
        song.loops.append(second)
        resortLoops(song)
        if selectedLoopID == loop.id && loopOn {
            engine.setLoop(start: loop.start, end: loop.end)
        }
        try? context.save()
    }

    func deleteLoop(_ loop: LoopRegion, context: ModelContext) {
        guard let song = currentSong else { return }
        let wasSelected = selectedLoopID == loop.id
        song.loops.removeAll { $0.id == loop.id }
        // Remove from any group membership, then prune emptied groups.
        var data = groupData(song)
        for i in data.indices { data[i].memberIDs.removeAll { $0 == loop.id } }
        applyGroupData(data, to: song, context: context)
        pruneEmptyGroups(song: song, context: context)
        context.delete(loop)
        if wasSelected {
            selectedLoopID = nil
            loopOn = false
            song.lastLoopID = nil
            engine.setLoop(start: nil, end: nil)
        }
        resortLoops(song)
        try? context.save()
    }

    private func resortLoops(_ song: Song) {
        let sorted = song.loops.sorted { ($0.start, $0.end, $0.createdAt) < ($1.start, $1.end, $1.createdAt) }
        for (i, loop) in sorted.enumerated() { loop.sortOrder = i }
    }

    private func haptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - Groups (PLAN §3 decision 12, §6)

    func groupData(_ song: Song) -> [GroupData] {
        song.groups.map { GroupData(id: $0.id, memberIDs: $0.memberIDs) }
    }

    func spans(_ song: Song) -> [UUID: LoopSpan] {
        Dictionary(uniqueKeysWithValues: song.loops.map { ($0.id, LoopSpan(id: $0.id, start: $0.start, end: $0.end)) })
    }

    func createGroup(name: String, context: ModelContext) {
        guard let song = currentSong else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = LoopGroup(name: trimmed, song: song)
        song.groups.append(group)
        try? context.save()
    }

    /// Checklist membership save: exact member set for one group.
    func setGroupMembers(_ group: LoopGroup, memberIDs: [UUID], context: ModelContext) {
        guard let song = currentSong else { return }
        var data = GroupOps.settingMembers(of: group.id, to: memberIDs, in: groupData(song))
        let spans = spans(song)
        for i in data.indices {
            data[i].memberIDs = GroupOps.sortedMemberIDs(data[i].memberIDs, groups: data, spans: spans)
        }
        applyGroupData(data, to: song, context: context)
        pruneEmptyGroups(song: song, context: context, keep: group.id)
        try? context.save()
    }

    /// Delete a group: children promote to its parent (PLAN §6).
    func deleteGroup(_ group: LoopGroup, context: ModelContext) {
        guard let song = currentSong else { return }
        let data = GroupOps.deletingGroup(group.id, from: groupData(song))
        context.delete(group)
        applyGroupData(data, to: song, context: context)
        pruneEmptyGroups(song: song, context: context)
        try? context.save()
    }

    func renameGroup(_ group: LoopGroup, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        try? context.save()
    }

    private func applyGroupData(_ data: [GroupData], to song: Song, context: ModelContext) {
        let byID = Dictionary(uniqueKeysWithValues: data.map { ($0.id, $0) })
        for group in song.groups {
            if let d = byID[group.id] { group.memberIDs = d.memberIDs }
        }
        let vanished = song.groups.filter { byID[$0.id] == nil }
        for group in vanished {
            song.groups.removeAll { $0.id == group.id }
            context.delete(group)
        }
    }

    /// Delete group records that no longer contain any loop (PLAN §6),
    /// optionally sparing one group (the one just edited via checklist).
    private func pruneEmptyGroups(song: Song, context: ModelContext, keep: UUID? = nil) {
        let loopIDs = Set(song.loops.map(\.id))
        let empty = GroupOps.emptyGroupIDs(groups: groupData(song), loopIDs: loopIDs)
        for group in song.groups where empty.contains(group.id) && group.id != keep {
            song.groups.removeAll { $0.id == group.id }
            context.delete(group)
        }
    }

    // MARK: - Position bookkeeping

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                if let p = self.engine.currentPosition() {
                    self.position = p
                    // End-of-file detection applies only outside loop mode;
                    // a wrapped loop position can legitimately touch the
                    // duration boundary (loop ending at the file end).
                    if !self.loopOn, let song = self.currentSong, p >= song.duration - 0.02 {
                        self.isPlaying = false
                        self.position = song.duration
                        self.savePosition()
                    }
                }
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// Persist the resume point (throttled by callers: pause, seek,
    /// close — PLAN §11).
    func savePosition() {
        guard let song = currentSong else { return }
        song.lastPosition = position >= song.duration ? 0 : position
    }
}
