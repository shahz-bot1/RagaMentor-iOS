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

    /// The range currently armed for looping: the selected loop's,
    /// or the selected group's derived range.
    public var armedLoopRange: (start: Double, end: Double)? {
        if let loop = selectedLoop { return (loop.start, loop.end) }
        if selectedGroupID != nil { return groupRange }
        return nil
    }
    private var groupRange: (start: Double, end: Double)?

    public var selectedLoop: LoopRegion? {
        guard let song = currentSong, let id = selectedLoopID else { return nil }
        return song.loops.first { $0.id == id }
    }

    let engine: any FilePlaybackEngine
    /// The shared raga-selection service (P1).
    public let ragaLibrary: any RagaLibrary
    /// The app's ONE sequence player (P-E), built by the app
    /// shell over the shell's one tone engine and handed in;
    /// every studio's adapter wraps it.
    public let sequencePlayer: SequencePlayer
    /// Phrase playback shared by the Swaras section and the editor (P1).
    public let phraseAdapter: PhraseAdapter
    private var positionTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false

    public init(engine: any FilePlaybackEngine = AudioEngine(),
                library: (any RagaLibrary)? = nil,
                sequencePlayer: SequencePlayer) {
        self.engine = engine
        self.ragaLibrary = library ?? DefaultRagaLibrary()
        self.sequencePlayer = sequencePlayer
        self.phraseAdapter = PhraseAdapter(player: sequencePlayer)
        engine.rate = speed
        observeSessionNotifications()
        setupRemoteCommands()
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

    // MARK: - Now Playing (metadata + remote commands, P6)

    /// Fired when song playback starts, so AppShell can stop the
    /// other studios (P6 audio focus).
    public var onSongStart: (() -> Void)?
    /// Fired when a Swaras section phrase starts (same purpose).
    public var onPhraseStart: (() -> Void)?

    /// A request to fit the waveform window to a range (v1.5.12):
    /// selectLoop / selectGroup publish it and the waveform area
    /// applies WaveformWindow.fitting. The id makes re-selecting
    /// the same range a fresh request.
    public struct ZoomRequest: Equatable {
        public let id: Int
        public let start: Double
        public let end: Double
    }
    @Published public private(set) var zoomRequest: ZoomRequest?
    private var zoomRequestCount = 0

    private func requestZoom(from start: Double, to end: Double) {
        zoomRequestCount += 1
        zoomRequest = ZoomRequest(id: zoomRequestCount, start: start, end: end)
    }

    private var remoteCommandsInstalled = false

    /// Lock-screen / Control Centre / headphone controls: play,
    /// pause, toggle, ±10 s skips and position scrubbing, all
    /// delegating to the same transport the UI uses.
    private func setupRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remoteResult { $0.play() }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remoteResult { $0.pause() }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remoteResult { $0.togglePlay() }
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remoteResult { $0.skip(by: 10) }
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remoteResult { $0.skip(by: -10) }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let target = positionEvent.positionTime
            return self.remoteResult { $0.seek(to: target) }
        }
    }

    /// Remote handlers run off the main queue; hop and report.
    private func remoteResult(_ action: @escaping (PlaybackController) -> Void)
        -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in action(self) }
        return currentSong == nil ? .noSuchContent : .success
    }

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
        if isPlaying {
            engine.pause()
            isPlaying = false
            savePosition()
        } else {
            if engine.loadedFile == nil, let song = currentSong { open(song) }
            if position >= (currentSong?.duration ?? 0) - 0.05 { position = 0 }
            // play(from:) restarts the schedule at `position`; if the engine
            // was merely paused mid-schedule this is still correct because
            // the schedule restarts from the published position.
            beginSongPlayback(from: position)
        }
        updateNowPlayingInfo()
    }

    /// The one song-start funnel (v1.5.11): every path that starts
    /// the song engine routes through here, so the app-wide
    /// single-playback rule cannot be bypassed. It stops the
    /// phrase adapter and fires the focus hook (wired in the
    /// shell to StudioAudioFocus.stopAll, which stops a playing
    /// scale, varisai pass or tala). selectLoop and selectGroup
    /// used to call the engine directly — a playing swara phrase
    /// sounded over the song (his bug report).
    private func beginSongPlayback(from seconds: Double) {
        phraseAdapter.stop()
        onSongStart?()
        engine.play(from: seconds)
        isPlaying = true
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

    /// The group the NEXT created loop joins (the web's in-group
    /// ＋ New loop: "define a new loop anywhere in the song — it
    /// will join this group"). Set by the Loops tab chips, consumed
    /// by createLoop, cleared when the Loops tab reappears without
    /// a creation.
    public var pendingLoopGroupID: UUID?

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
        if let groupID = pendingLoopGroupID {
            pendingLoopGroupID = nil
            if let group = song.groups.first(where: { $0.id == groupID }) {
                fileLoop(loop, into: group, song: song, context: context)
            }
        }
        selectLoop(loop, context: context, autoplay: isPlaying)
        try? context.save()
        return loop
    }

    /// File a loop into a group: append to the group's members,
    /// kept in range order (GroupOps sorting handles loops and
    /// subgroups alike).
    private func fileLoop(_ loop: LoopRegion, into group: LoopGroup,
                          song: Song, context: ModelContext) {
        var data = groupData(song)
        guard let idx = data.firstIndex(where: { $0.id == group.id }) else { return }
        data[idx].memberIDs = GroupOps.sortedMemberIDs(
            data[idx].memberIDs + [loop.id], groups: data, spans: spans(song))
        applyGroupData(data, to: song, context: context)
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
        selectedGroupID = nil
        groupRange = nil
        selectedLoopID = loop.id
        song.lastLoopID = loop.id
        loopOn = true
        engine.setLoop(start: loop.start, end: loop.end)
        position = loop.start
        if autoplay {
            beginSongPlayback(from: loop.start)
        } else {
            engine.seek(to: loop.start)
            engine.pause()
        }
        requestZoom(from: loop.start, to: loop.end)
        try? context.save()
    }

    /// Arm/disarm looping of the selected loop without changing selection.
    /// (engine.setLoop restarts playback in the new mode when playing.)
    public func toggleLoopOn() {
        if let loop = selectedLoop {
            loopOn.toggle()
            engine.setLoop(start: loopOn ? loop.start : nil,
                           end: loopOn ? loop.end : nil)
        } else if selectedGroupID != nil, let range = groupRange {
            loopOn.toggle()
            engine.setLoop(start: loopOn ? range.start : nil,
                           end: loopOn ? range.end : nil)
        }
    }

    /// Deselect the armed loop entirely (web: tapping the active
    /// loop chip again). Looping disarms; playback continues.
    public func clearLoopSelection() {
        selectedLoopID = nil
        selectedGroupID = nil
        groupRange = nil
        loopOn = false
        engine.setLoop(start: nil, end: nil)
        if let song = currentSong {
            song.lastLoopID = nil
        }
    }

    /// Select a GROUP: arm its derived range (first member's start →
    /// last member's end) and play it, without selecting a single
    /// loop — the web's group-chip behaviour ("open group and loop
    /// the whole section"). Tracks the armed group so the chips UI
    /// can mark it.
    @Published public private(set) var selectedGroupID: UUID?

    public func selectGroup(_ group: LoopGroup, context: ModelContext) {
        guard let song = currentSong,
              let range = GroupLogic.derivedRange(
                groupID: group.id,
                children: Dictionary(uniqueKeysWithValues: song.groups.map { ($0.id, $0.memberIDs) }),
                spans: Dictionary(uniqueKeysWithValues: song.loops.map {
                    ($0.id, LoopSpan(id: $0.id, start: $0.start, end: $0.end))
                })) else { return }
        selectedLoopID = nil
        selectedGroupID = group.id
        groupRange = range
        song.lastLoopID = nil
        loopOn = true
        engine.setLoop(start: range.start, end: range.end)
        position = range.start
        beginSongPlayback(from: range.start)
        requestZoom(from: range.start, to: range.end)
        try? context.save()
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

    /// Set one edge of a loop at an absolute time (the A–B tab's Set
    /// buttons with a loop selected — the web writes the playhead
    /// into the editing loop's edge).
    public func setLoopEdge(_ loop: LoopRegion, edge: Edge, at time: Double, context: ModelContext) {
        guard let song = currentSong else { return }
        let newStart = edge == .start ? time : loop.start
        let newEnd = edge == .end ? time : loop.end
        guard let range = LoopRules.normalize(start: newStart, end: newEnd, duration: song.duration) else { return }
        loop.start = range.start
        loop.end = range.end
        resortLoops(song)
        if selectedLoopID == loop.id && loopOn {
            engine.setLoop(start: loop.start, end: loop.end)
        }
        try? context.save()
    }

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

    /// The web's group colour palette, cycled by group count.
    public static let groupPalette = ["#2dd4bf", "#fbbf24", "#a78bfa", "#fb7185", "#38bdf8"]

    /// The web's auto-name for a new group: the first free
    /// "Group N", counting up from the group count.
    public static func nextGroupName(existing: [String]) -> String {
        let used = Set(existing)
        var n = existing.count + 1
        while used.contains("Group \(n)") { n += 1 }
        return "Group \(n)"
    }

    /// Create a group the web's way (v1.5.12): instantly, with
    /// the auto-name and the next palette colour, filed inside
    /// the parent when one is given (the view enforces the
    /// 2-level cap by only offering it for parentless groups).
    /// The group starts EMPTY; the caller opens the membership
    /// checklist on it, whose Cancel removes it again.
    @discardableResult
    public func createGroup(inside parent: LoopGroup? = nil,
                            context: ModelContext) -> LoopGroup? {
        guard let song = currentSong else { return nil }
        let group = LoopGroup(
            name: Self.nextGroupName(existing: song.groups.map(\.name)),
            colorHex: Self.groupPalette[song.groups.count % Self.groupPalette.count],
            song: song)
        song.groups.append(group)
        if let parent, song.groups.contains(where: { $0.id == parent.id }) {
            var data = groupData(song)
            if let idx = data.firstIndex(where: { $0.id == parent.id }) {
                data[idx].memberIDs = GroupOps.sortedMemberIDs(
                    data[idx].memberIDs + [group.id], groups: data, spans: spans(song))
                applyGroupData(data, to: song, context: context)
            }
        }
        try? context.save()
        return group
    }

    /// Checklist candidates — the web's strict level rules
    /// (v1.5.12), as item ids sorted by range start (a group
    /// sorts by its derived range):
    /// - new top-level group: the items visible at the top
    ///   level — ungrouped loops + flat parentless groups
    ///   (never anything nested inside another group);
    /// - new sub-group: the parent's DIRECT member loops only
    ///   (never loops inside the parent's own sub-groups);
    /// - existing group (the reorganize tool): every loop,
    ///   plus flat parentless groups when this group is
    ///   top-level. A "flat" group holds loops only (the
    ///   2-level cap).
    public func checklistCandidateIDs(for group: LoopGroup, isNew: Bool) -> [UUID] {
        guard let song = currentSong else { return [] }
        let data = groupData(song)
        let parent = GroupOps.parentMap(groups: data)
        let groupIDs = Set(data.map(\.id))
        let spanMap = spans(song)
        func isFlat(_ g: GroupData) -> Bool {
            !g.memberIDs.contains { groupIDs.contains($0) }
        }
        func flatParentless() -> [UUID] {
            data.filter { $0.id != group.id && parent[$0.id] == nil && isFlat($0) }
                .map(\.id)
        }
        func start(of id: UUID) -> Double {
            if let loop = song.loops.first(where: { $0.id == id }) { return loop.start }
            return GroupLogic.derivedRange(
                groupID: id,
                children: Dictionary(uniqueKeysWithValues: data.map { ($0.id, $0.memberIDs) }),
                spans: spanMap)?.start ?? .greatestFiniteMagnitude
        }
        let ids: [UUID]
        if isNew, let parentID = parent[group.id] {
            let memberIDs = Set(data.first { $0.id == parentID }?.memberIDs ?? [])
            ids = song.loops.filter { memberIDs.contains($0.id) }.map(\.id)
        } else if isNew {
            ids = song.loops.filter { parent[$0.id] == nil }.map(\.id) + flatParentless()
        } else {
            var all = song.loops.map(\.id)
            if parent[group.id] == nil { all += flatParentless() }
            ids = all
        }
        return ids.sorted { start(of: $0) < start(of: $1) }
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
    /// phrases); import reads the same v3 format.
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

    /// Replace ALL loops/groups of the current song from backup data.
    /// The format is the platform-independent v3 (identical to the web
    /// export); import replaces and mints fresh DB ids. Returns false
    /// (changing nothing) when the data is not a usable v3 file.
    @discardableResult
    public func importBackup(data: Data, context: ModelContext) -> Bool {
        guard let song = currentSong,
              let plan = LoopsBackupV3.planImport(
                data: data, duration: song.duration,
                isKnownRaga: { [ragaLibrary] id in ragaLibrary.raga(id: id) != nil }) else {
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

        phraseAdapter.stop()
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
        if phraseAdapter.isPlaying(contextKey: sectionKey(for: loop))
            || phraseAdapter.isPlaying(contextKey: editorKey(for: loop)) {
            phraseAdapter.stop()
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
        if phraseAdapter.isPlaying(contextKey: sectionKey(for: loop)) {
            phraseAdapter.stop()
            return
        }
        guard let phrase = phrase(for: loop), !phrase.chips.isEmpty else { return }
        pause()
        startSectionPhrase(phrase, for: loop)
    }

    private func startSectionPhrase(_ phrase: Phrase, for loop: LoopRegion) {
        onPhraseStart?()
        let songID = currentSong?.id
        phraseAdapter.play(phrase: phrase, contextKey: sectionKey(for: loop)) { [weak self] in
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
        if phraseAdapter.isPlaying(contextKey: sectionKey(for: loop)) {
            startSectionPhrase(phrase, for: loop)
        }
    }
}
