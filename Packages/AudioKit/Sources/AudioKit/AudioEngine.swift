import Foundation
import AVFoundation
import RagaCore

// Audio engine per PLAN §7.
// Graph: AVAudioPlayerNode -> AVAudioUnitTimePitch -> gate mixer
// -> mainMixer -> output (the gate is v1.5.35, see gateMixer).
// M1: full-file playback, seek, live rate change, position reporting.
// M2: gapless segment looping (PLAN §7) — since v1.5.31 the loop
// passes are kept queued several deep and each completion tops
// the queue up, instead of one pass being scheduled from the
// previous pass's completion (see scheduleLoopSegment).

public final class AudioEngine: FilePlaybackEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// The output gate (v1.5.35): a mixer of our own between
    /// TimePitch and the main mixer. TimePitch holds a window
    /// of audio inside it; when the player pauses or restarts,
    /// that window keeps sounding, stretched — at 0.25x the
    /// tail runs ~4x longer than at 1x (his report: play/pause
    /// and the loop-name restart felt badly delayed at slow
    /// speeds). Transport actions slam this gate shut in ~10 ms
    /// so the tail never reaches the speaker; play opens it as
    /// the new schedule starts. The start prime itself is the
    /// vocoder's floor and stays.
    private let gateMixer = AVAudioMixerNode()
    /// Whether the gate is (heading) open. Set synchronously by
    /// every transport action; the volume ramp follows it.
    public private(set) var gateOpen = true
    private var gateToken = 0

    /// The gate's current output volume (ramps between 0 and 1).
    public var gateVolume: Float { gateMixer.outputVolume }

    private func setGate(open: Bool) {
        gateOpen = open
        gateToken += 1
        let token = gateToken
        let steps: [(delay: Double, volume: Float)] = open
            ? [(0, 0.4), (0.004, 0.75), (0.008, 1.0)]
            : [(0, 0.55), (0.003, 0.25), (0.006, 0.08), (0.009, 0.0)]
        for step in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                guard let self, self.gateToken == token else { return }
                self.gateMixer.outputVolume = step.volume
            }
        }
    }

    public private(set) var loadedFile: AVAudioFile?
    /// Frame offset where the current schedule started (file mode).
    private var scheduleStartFrame: AVAudioFramePosition = 0

    // Loop state (seconds, as set by the caller; frames derived on use).
    public private(set) var loopStart: Double?
    public private(set) var loopEnd: Double?
    public var loopEnabled: Bool { loopStart != nil && loopEnd != nil }
    /// Frame where the active loop segment starts (position math).
    private var loopStartFrame: AVAudioFramePosition = 0
    private var loopFrameCount: AVAudioFramePosition = 0
    /// Frame where the current loop playback entered (may be mid-segment;
    /// the first pass runs entry->end, later passes wrap the full segment).
    private var loopEntryFrame: AVAudioFramePosition = 0
    /// Bumped on every stop/mode change so stale segment completions
    /// never reschedule (LoopMath.shouldReschedule).
    private var generation = 0
    /// Loop passes kept queued on the node in realtime playback
    /// (v1.5.31). Three deep means a completion must arrive more
    /// than two whole passes late before the queue could starve.
    private static let loopPassQueueDepth = 3

    private var sessionConfigured = false

    public var isPlaying: Bool { playerNode.isPlaying }
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    public var duration: Double {
        guard let file = loadedFile, file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    public init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.attach(gateMixer)
        timePitch.pitch = 0 // pitch locked (PLAN §3 decision 3)
        rate = 1.0
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Load a file and prepare the graph in its processing format.
    public func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        stop()
        clearLoop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(gateMixer)
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: gateMixer, format: file.processingFormat)
        engine.connect(gateMixer, to: engine.mainMixerNode, format: file.processingFormat)
        loadedFile = file
        scheduleStartFrame = 0
    }

    private func ensureEngineRunning() {
        configureSessionIfNeeded()
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    // MARK: - Loop control

    /// Arm (or clear, with nil) the active loop. If playback is running it
    /// restarts inside the new mode; M3/M4 wire the UI around this.
    public func setLoop(start: Double?, end: Double?) {
        if let start, let end, end > start {
            loopStart = start
            loopEnd = end
        } else {
            loopStart = nil
            loopEnd = nil
        }
        if playerNode.isPlaying {
            // Restart in the new mode from the current position; the
            // scheduler enters the loop at that position when it falls
            // inside the segment, else at the loop start.
            play(from: currentPosition() ?? (loopStart ?? 0))
        }
    }

    public func clearLoop() {
        loopStart = nil
        loopEnd = nil
    }

    // MARK: - Transport

    /// Schedule playback from `seconds` and play. In loop mode playback
    /// always (re)starts at the loop start, per PLAN §7.
    public func play(from seconds: Double = 0) {
        guard loadedFile != nil else { return }
        ensureEngineRunning()
        schedule(from: seconds)
        setGate(open: true)
        playerNode.play()
    }

    /// Shared scheduling for realtime play and offline rendering.
    /// `preScheduleLoopPasses > 0` is the offline path: manual rendering
    /// does not pick up segments scheduled from completion handlers
    /// (observed in CI, M2 spike), so loop passes are queued up front.
    /// Realtime playback passes 0 and re-schedules from the completion.
    private func schedule(from seconds: Double, preScheduleLoopPasses: Int = 0) {
        guard let file = loadedFile else { return }
        generation += 1
        playerNode.stop()
        let sampleRate = file.fileFormat.sampleRate

        if loopEnabled, let ls = loopStart, let le = loopEnd {
            loopStartFrame = TimeMath.frames(forSeconds: ls, sampleRate: sampleRate)
            let endFrame = TimeMath.frames(forSeconds: le, sampleRate: sampleRate)
            loopFrameCount = max(1, endFrame - loopStartFrame)
            // Enter at the requested position when it falls inside the
            // loop, else at the loop start.
            let wanted = TimeMath.frames(forSeconds: seconds, sampleRate: sampleRate)
            loopEntryFrame = (wanted >= loopStartFrame && wanted < endFrame) ? wanted : loopStartFrame
            if preScheduleLoopPasses > 0 {
                scheduleSegmentPass(startFrame: loopEntryFrame)
                for _ in 1..<preScheduleLoopPasses {
                    scheduleSegmentPass(startFrame: loopStartFrame)
                }
            } else {
                // Fill the realtime queue to depth: the entry
                // pass plus full passes queued behind it.
                scheduleLoopSegment(generation: generation, firstPass: true)
                for _ in 1..<Self.loopPassQueueDepth {
                    scheduleLoopSegment(generation: generation)
                }
            }
        } else {
            let startFrame = TimeMath.frames(forSeconds: max(0, seconds), sampleRate: sampleRate)
            let clampedStart = min(startFrame, max(0, file.length - 1))
            let frameCount = AVAudioFrameCount(max(0, file.length - clampedStart))
            scheduleStartFrame = clampedStart
            if frameCount > 0 {
                playerNode.scheduleSegment(file,
                                           startingFrame: clampedStart,
                                           frameCount: frameCount,
                                           at: nil)
            }
        }
    }

    /// Schedule one loop pass with no completion handler (offline path).
    private func scheduleSegmentPass(startFrame: AVAudioFramePosition) {
        guard let file = loadedFile, loopFrameCount > 0 else { return }
        let count = loopStartFrame + loopFrameCount - startFrame
        guard count > 0 else { return }
        playerNode.scheduleSegment(file,
                                   startingFrame: startFrame,
                                   frameCount: AVAudioFrameCount(count),
                                   at: nil)
    }

    /// Schedule one pass of the loop segment, keeping the
    /// realtime queue loopPassQueueDepth deep (v1.5.31): the
    /// initial fill queues that many passes, and each pass's
    /// completion schedules exactly one replacement, so the
    /// depth is invariant while the loop runs. Queued segments
    /// play sample-exactly back to back, so a seam can no longer
    /// gap when a completion lands late — the failure this
    /// replaces, where the next pass was scheduled only after
    /// the previous one ended: the sample clock kept counting
    /// through the gap while the audio restarted late, and the
    /// playhead (modulo position over the clock) drifted
    /// further from the audible loop at every late seam (his
    /// report, 2026-10-21). The first pass may start
    /// mid-segment (loopEntryFrame).
    private func scheduleLoopSegment(generation gen: Int, firstPass: Bool = false) {
        guard let file = loadedFile, loopFrameCount > 0 else { return }
        let startFrame = firstPass ? loopEntryFrame : loopStartFrame
        let count = loopStartFrame + loopFrameCount - startFrame
        guard count > 0 else { return }
        playerNode.scheduleSegment(file,
                                   startingFrame: startFrame,
                                   frameCount: AVAudioFrameCount(count),
                                   at: nil,
                                   completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            if LoopMath.shouldReschedule(loopEnabled: self.loopEnabled,
                                         eventGeneration: gen,
                                         currentGeneration: self.generation) {
                self.scheduleLoopSegment(generation: gen)
            }
        }
    }

    public func pause() {
        // Gate first: the vocoder tail is silenced before the
        // node even stops, so pause lands instantly at any rate.
        setGate(open: false)
        playerNode.pause()
    }

    public func resume() {
        ensureEngineRunning()
        setGate(open: true)
        playerNode.play()
    }

    public func stop() {
        generation += 1
        setGate(open: false)
        playerNode.stop()
        scheduleStartFrame = 0
    }

    public func seek(to seconds: Double) {
        let wasPlaying = playerNode.isPlaying
        play(from: seconds)
        if !wasPlaying {
            playerNode.pause()
            // play(from:) opened the gate; a paused seek must
            // end gated, or the seek's primed audio leaks.
            setGate(open: false)
        }
    }

    /// Current playhead position in seconds, from the render clock
    /// (PLAN §7 position reporting). In loop mode the position wraps
    /// inside the segment. Nil when nothing is scheduled.
    public func currentPosition() -> Double? {
        guard let file = loadedFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        if loopEnabled {
            return LoopMath.loopPosition(segmentStartFrame: loopStartFrame,
                                         segmentFrameCount: loopFrameCount,
                                         firstPassOffsetFrames: loopEntryFrame - loopStartFrame,
                                         playedFrames: playerTime.sampleTime,
                                         sampleRate: sampleRate)
        }
        let frames = scheduleStartFrame + playerTime.sampleTime
        let seconds = TimeMath.seconds(forFrames: frames, sampleRate: sampleRate)
        return TimeMath.clamp(seconds, min: 0, max: duration)
    }

    // MARK: - Offline rendering (analysis + tests; PLAN §13 M2 spike)

    /// Render the current schedule (file or loop mode, current rate)
    /// without hardware, using AVAudioEngine manual rendering. Returns a
    /// mono-downmixed buffer of exactly the requested frame count
    /// (silence-padded if the schedule runs out).
    public func renderOffline(from seconds: Double, frames requestedFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let file = loadedFile else { return nil }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        // The render pulls through the gate: force it open, or a
        // paused engine renders silence (v1.5.35). The prior gate
        // state is restored on the way out.
        let priorGateOpen = gateOpen
        stop()
        gateToken += 1
        gateOpen = true
        gateMixer.outputVolume = 1
        try engine.enableManualRenderingMode(.offline,
                                             format: file.processingFormat,
                                             maximumFrameCount: 8192)
        defer {
            playerNode.stop()
            engine.disableManualRenderingMode()
            gateToken += 1
            gateOpen = priorGateOpen
            gateMixer.outputVolume = priorGateOpen ? 1 : 0
        }
        // In loop mode, queue enough passes up front to cover the request
        // (completion re-scheduling does not work in manual rendering).
        var passes = 0
        if loopEnabled, let ls = loopStart, let le = loopEnd {
            let frames = TimeMath.frames(forSeconds: le, sampleRate: file.fileFormat.sampleRate)
                - TimeMath.frames(forSeconds: ls, sampleRate: file.fileFormat.sampleRate)
            if frames > 0 {
                let outputPerPass = Double(frames) / Double(max(rate, 0.01))
                passes = Int((Double(requestedFrames) / max(outputPerPass, 1)).rounded(.up)) + 2
            }
        }
        schedule(from: seconds, preScheduleLoopPasses: passes)
        try engine.start()
        playerNode.play()

        let format = engine.manualRenderingFormat
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requestedFrames),
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
        var rendered: AVAudioFrameCount = 0
        while rendered < requestedFrames {
            let want = min(AVAudioFrameCount(8192), requestedFrames - rendered)
            let status = try engine.renderOffline(want, to: chunk)
            let got = chunk.frameLength
            if got > 0 {
                copyFrames(from: chunk, to: out, at: rendered)
                rendered += got
            }
            if status == .error || got == 0 { break }
        }
        out.frameLength = rendered
        return out
    }

    private func copyFrames(from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer, at offset: AVAudioFrameCount) {
        let channels = Int(min(src.format.channelCount, dst.format.channelCount))
        guard let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        for ch in 0..<channels {
            for i in 0..<Int(src.frameLength) {
                d[ch][Int(offset) + i] = s[ch][i]
            }
        }
    }
}
