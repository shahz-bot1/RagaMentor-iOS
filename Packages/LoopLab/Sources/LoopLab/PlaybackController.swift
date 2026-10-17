import Foundation
import SwiftData
import RagaCore
import AudioKit
import PersistenceKit
import SwaraEditor
import Combine
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

// LoopLab feature (PARITY-PLAN §3.1): the playback view model.
// Single source of truth for playback state (PLAN §5): transport,
// speed, current song, playhead position (~20 Hz publish).

@MainActor
public final class PlaybackController: ObservableObject {
    @Published public private(set) var currentSong: Song?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: Double = 0
    @Published public var speed: Float = 1.0 {
        didSet {
            engine.rate = speed
            updateNowPlayingInfo()
        }
    }
    @Published public var importError: String?
    @Published public var playbackError: String?

    /// Speed presets, slowest first (PLAN §2/§10).
    public static let speedPresets: [Float] = [0.25, 0.5, 0.75, 1.0]

    // MARK: Loop state (M3, PLAN §10)

    /// The loop the chips/A–B actions refer to.
    @Published public private(set) var selectedLoopID: UUID?
    /// Whether the selected loop is armed in the engine.
    @Published public private(set) var loopOn = false
    /// Pending A / B marks while creating a loop from the A–B controls.
    @Published public private(set) var pendingA: Double?
    @Published public private(set) var pendingB: Double?

    public var selectedLoop: LoopRegion? {
        guard let song = currentSong, let id = selectedLoopID else { return nil }
        return song.loops.first { $0.id == id }
    }

    let engine: any FilePlaybackEngine
    /// The shared raga-selection service (P1).
    public let ragaLibrary: any RagaLibrary
    /// Phrase playback shared by the Swaras section and the editor (P1).
    public let phrasePlayer: PhrasePlayer
    private var positionTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    public init(engine: any FilePlaybackEngine = AudioEngine(),
                library: (any RagaLibrary)? = nil,
                tone: (any ToneEngine)? = nil) {
        self.engine = engine
        self.ragaLibrary = library ?? DefaultRagaLibrary()
        self.phrasePlayer = PhrasePlayer(tone: tone ?? HarmoniumToneEngine())
        engine.rate = speed
        observeSessionNotifications()
    }

    // MARK: - Interruptions & route changes (M6, PLAN §8.7)

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Media services reset: reload the current song from scratch.
            Task { @MainActor in
                guard let self, let song = self.currentSong else { return }
                let wasPlaying = self.isPlaying
                self.open(song)
                if wasPlaying { self.play() }
            }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                if self.isPlaying {
                    self.resumeAfterInterruption = true
                    self.pause()
                }
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if self.resumeAfterInterruption && options.contains(.shouldResume) {
                    self.play()
                }
                self.resumeAfterInterruption = false
            @unknown default:
                break
            }
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        Task { @MainActor in
            // Headphones unplugged / device removed: pause (standard).
            if reason == .oldDeviceUnavailable && self.isPlaying {
                self.pause()
            }
        }
    }

    // MARK: - Now Playing info (metadata only; remote commands are v1.1)

    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyPlaybackDuration: song.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
        ]
    }

    // MARK: - Song selection

    /// Open a song: load its file and restore the saved position (PLAN §11).
    public func open(_ song: Song) {
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
        updateNowPlayingInfo()
        startPositionTimer()
    }

    public func closeSong() {
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
        updateNowPlayingInfo()
        stopPositionTimer()
    }

    // MARK: - Transport

    public func togglePlay() {
        guard currentSong != nil else { return }
        phrasePlayer.stop()
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
        updateNowPlayingInfo()
    }

    public func play() {
        if !isPlaying { togglePlay() }
    }

    public func pause() {
        if isPlaying { togglePlay() }
    }

    public func seek(to seconds: Double) {
        guard let song = currentSong else { return }
        position = TimeMath.clamp(seconds, min: 0, max: song.duration)
        engine.seek(to: position)
        if !isPlaying { engine.pause() }
        savePosition()
        updateNowPlayingInfo()
    }

    public func skip(by delta: Double) {
        seek(to: position + delta)
    }

    // MARK: - Library actions

    /// Import picked files; returns the last imported/opened song so the
    /// caller can select it. Dedupe is handled in ImportService.
    @discardableResult
    public func importFiles(_ urls: [URL], context: ModelContext) -> Song? {
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
    public func deleteSong(_ song: Song, context: ModelContext) {
        if currentSong?.id == song.id { closeSong() }
        ImportService.removeStoredFile(for: song)
        context.delete(song)
        try? context.save()
    }

    // MARK: - Loop creation (A–B marks)

    public func setA() { pendingA = position; completeLoopIfReady() }
    public func setB() { pendingB = position; completeLoopIfReady() }
    public func clearPendingMarks() { pendingA = nil; pendingB = nil }

    /// 0.1 s steppers for a pending mark (PLAN §10 A–B tab).
    public func nudgePending(edge: Edge, by delta: Double) {
        guard let song = currentSong else { return }
        if edge == .start, let a = pendingA {
            pendingA = TimeMath.clamp(a + delta, min: 0, max: song.duration)
        }
        if edge == .end, let b = pendingB {
            pendingB = TimeMath.clamp(b + delta, min: 0, max: song.duration)
        }
    }

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
    public var modelContext: ModelContext?

    /// Create a loop from two marks: normalises (auto-swap when B <= A,
    /// with a haptic — PLAN §12), names it, selects and arms it.
    @discardableResult
    public func createLoop(start rawStart: Double, end rawEnd: Double, context: ModelContext) -> LoopRegion? {
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
    public func selectLoop(_ loop: LoopRegion, context: ModelContext, autoplay: Bool = true) {
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
    /// (engine.setLoop restarts playback in the new mode when playing.)
    public func toggleLoopOn() {
        guard let loop = selectedLoop else { return }
        loopOn.toggle()
        engine.setLoop(start: loopOn ? loop.start : nil,
                       end: loopOn ? loop.end : nil)
    }

    public func renameLoop(_ loop: LoopRegion, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loop.name = trimmed
        try? context.save()
    }

    public func setLoopNote(_ loop: LoopRegion, to note: String, context: ModelContext) {
        loop.note = note
        try? context.save()
    }

    /// 0.1 s nudge steppers (PLAN §10): adjusts one edge, re-normalised.
    public func nudgeLoop(_ loop: LoopRegion, edge: Edge, by delta: Double, context: ModelContext) {
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

    public enum Edge { case start, end }

    /// Split the loop at the current playhead (PLAN §10 A–B rules).
    public func splitLoop(_ loop: LoopRegion, context: ModelContext) {
        guard let song = currentSong,
              LoopRules.canSplit(loopStart: loop.start, loopEnd: loop.end, at: position) else { return }
        let originalEnd = loop.end
        loop.end = position
        let second = LoopRegion(name: LoopRules.splitSecondName(originalName: loop.name,
                                                                 existingNames: song.loops.map(\.name)),
                                note: loop.note,
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

    public func deleteLoop(_ loop: LoopRegion, context: ModelContext) {
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

    public func groupData(_ song: Song) -> [GroupData] {
        song.groups.map { GroupData(id: $0.id, memberIDs: $0.memberIDs) }
    }

    public func spans(_ song: Song) -> [UUID: LoopSpan] {
        Dictionary(uniqueKeysWithValues: song.loops.map { ($0.id, LoopSpan(id: $0.id, start: $0.start, end: $0.end)) })
    }

    public func createGroup(name: String, context: ModelContext) {
        guard let song = currentSong else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = LoopGroup(name: trimmed, song: song)
        song.groups.append(group)
        try? context.save()
    }

    /// Checklist membership save: exact member set for one group.
    public func setGroupMembers(_ group: LoopGroup, memberIDs: [UUID], context: ModelContext) {
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
    public func deleteGroup(_ group: LoopGroup, context: ModelContext) {
        guard let song = currentSong else { return }
        let data = GroupOps.deletingGroup(group.id, from: groupData(song))
        context.delete(group)
        applyGroupData(data, to: song, context: context)
        pruneEmptyGroups(song: song, context: context)
        try? context.save()
    }

    public func renameGroup(_ group: LoopGroup, to name: String, context: ModelContext) {
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
    public func savePosition() {
        guard let song = currentSong else { return }
        song.lastPosition = position >= song.duration ? 0 : position
        try? modelContext?.save()
    }

    // MARK: - Loops backup (M4, PLAN §11)

    /// Serialise the current song's loops/groups to backup JSON.
    /// P1: writes the web-compatible v3 format (loops carry their swara
    /// phrases); import still reads native v1 files.
    public func backupJSON() -> Data? {
        guard let song = currentSong else { return nil }
        return LoopsBackupV3.makeData(
            songTitle: song.title,
            loops: song.loops.map { .init(id: $0.id, name: $0.name, note: $0.note,
                                          start: $0.start, end: $0.end,
                                          phrase: phrase(for: $0)) },
            groups: song.groups.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex, memberIDs: $0.memberIDs) },
            isKnownRaga: { [ragaLibrary] id in ragaLibrary.raga(id: id) != nil })
    }

    /// Replace ALL loops/groups of the current song from backup data
    /// (PLAN §11: import replaces; fresh DB ids are minted).
    /// Returns false (changing nothing) when the file is not a valid
    /// v1 backup.
    @discardableResult
    public func importBackup(data: Data, context: ModelContext) -> Bool {
        guard let song = currentSong else { return false }
        let plan: (loops: [LoopsBackup.PlannedLoop], groups: [LoopsBackup.PlannedGroup])
        if let file = try? JSONDecoder().decode(LoopsBackupFile.self, from: data),
           let v1 = try? LoopsBackup.planImport(file: file, duration: song.duration) {
            plan = v1
        } else if let v3 = LoopsBackupV3.planImport(
            data: data, duration: song.duration,
            isKnownRaga: { [ragaLibrary] id in ragaLibrary.raga(id: id) != nil }) {
            plan = v3
        } else {
            return false
        }
        // Disarm playback selection first (records are about to vanish).
        selectedLoopID = nil
        loopOn = false
        song.lastLoopID = nil
        engine.setLoop(start: nil, end: nil)

        for loop in song.loops { context.delete(loop) }
        song.loops = []
        for group in song.groups { context.delete(group) }
        song.groups = []

        phrasePlayer.stop()
        for planned in plan.loops {
            let loop = LoopRegion(id: planned.id, name: planned.name, note: planned.note,
                                  start: planned.start, end: planned.end,
                                  swarasJSON: planned.phrase?.jsonString(), song: song)
            song.loops.append(loop)
        }
        resortLoops(song)
        for planned in plan.groups {
            let group = LoopGroup(id: planned.id, name: planned.name,
                                  colorHex: planned.colorHex, memberIDs: planned.memberIDs,
                                  song: song)
            song.groups.append(group)
        }
        try? context.save()
        return true
    }

    // MARK: - Swara phrases (P1)

    public func phrase(for loop: LoopRegion) -> Phrase? {
        loop.swarasJSON.flatMap(Phrase.fromJSONString)
    }

    /// A loop "has" a phrase when it holds at least one chip (web
    /// swHasPhrase).
    public func hasPhrase(_ loop: LoopRegion) -> Bool {
        phrase(for: loop).map { !$0.chips.isEmpty } ?? false
    }

    public func savePhrase(_ phrase: Phrase, for loop: LoopRegion, context: ModelContext) {
        loop.swarasJSON = phrase.jsonString()
        try? context.save()
        objectWillChange.send()
    }

    public func clearPhrase(for loop: LoopRegion, context: ModelContext) {
        if phrasePlayer.isPlaying(contextKey: sectionKey(for: loop))
            || phrasePlayer.isPlaying(contextKey: editorKey(for: loop)) {
            phrasePlayer.stop()
        }
        loop.swarasJSON = nil
        try? context.save()
        objectWillChange.send()
    }

    /// Per-song raga memory (web swNoteSongRaga).
    public func noteSongRaga(_ id: String?, context: ModelContext) {
        currentSong?.swRagaId = id
        try? context.save()
    }

    /// The default phrase for a loop with none: the song's remembered
    /// raga, else Mohanam; tempo 72 (web swDefaultPhrase).
    public func defaultPhrase(for song: Song) -> Phrase {
        let rid = song.swRagaId.flatMap { ragaLibrary.raga(id: $0) != nil ? $0 : nil } ?? "mohanam"
        return Phrase(ragaId: rid, saOffset: 0, tempo: 72, loop: false, chips: [])
    }

    public func sectionKey(for loop: LoopRegion) -> String { "section:\(loop.id.uuidString)" }
    public func editorKey(for loop: LoopRegion) -> String { "editor:\(loop.id.uuidString)" }

    public func toggleSectionPhrase(for loop: LoopRegion) {
        if phrasePlayer.isPlaying(contextKey: sectionKey(for: loop)) {
            phrasePlayer.stop()
            return
        }
        guard let phrase = phrase(for: loop), !phrase.chips.isEmpty else { return }
        pause()
        startSectionPhrase(phrase, for: loop)
    }

    private func startSectionPhrase(_ phrase: Phrase, for loop: LoopRegion) {
        let songID = currentSong?.id
        phrasePlayer.play(phrase: phrase, contextKey: sectionKey(for: loop)) { [weak self] in
            // Web ctx validity: the fullscreen section for this loop.
            self?.selectedLoopID == loop.id && self?.currentSong?.id == songID
        }
    }

    /// Section tempo slider: writes the stored phrase's tempo and
    /// restarts section playback when it is playing (web behaviour).
    public func setSectionPhraseTempo(_ tempo: Int, for loop: LoopRegion, context: ModelContext) {
        guard var phrase = phrase(for: loop) else { return }
        phrase.tempo = min(120, max(30, tempo))
        savePhrase(phrase, for: loop, context: context)
        if phrasePlayer.isPlaying(contextKey: sectionKey(for: loop)) {
            startSectionPhrase(phrase, for: loop)
        }
    }
}
