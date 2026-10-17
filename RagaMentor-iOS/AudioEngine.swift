import Foundation
import AVFoundation

// Audio engine per PLAN §7.
// Graph: AVAudioPlayerNode -> AVAudioUnitTimePitch -> mainMixer -> output.
// M1: full-file playback, seek, live rate change, position reporting.
// M2 adds gapless segment looping on this same graph.

final class AudioEngine {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private(set) var loadedFile: AVAudioFile?
    /// Frame offset where the current schedule started.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    private var sessionConfigured = false

    var isPlaying: Bool { playerNode.isPlaying }
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    var duration: Double {
        guard let file = loadedFile, file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
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
    func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
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

    /// Schedule the loaded file from `seconds` and play.
    func play(from seconds: Double = 0) {
        guard let file = loadedFile else { return }
        ensureEngineRunning()
        playerNode.stop()
        let startFrame = TimeMath.frames(forSeconds: max(0, seconds),
                                         sampleRate: file.fileFormat.sampleRate)
        let clampedStart = min(startFrame, max(0, file.length - 1))
        let frameCount = AVAudioFrameCount(max(0, file.length - clampedStart))
        scheduleStartFrame = clampedStart
        if frameCount > 0 {
            playerNode.scheduleSegment(file,
                                       startingFrame: clampedStart,
                                       frameCount: frameCount,
                                       at: nil)
        }
        playerNode.play()
    }

    func pause() {
        playerNode.pause()
    }

    func resume() {
        ensureEngineRunning()
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        scheduleStartFrame = 0
    }

    func seek(to seconds: Double) {
        let wasPlaying = playerNode.isPlaying
        play(from: seconds)
        if !wasPlaying { playerNode.pause() }
    }

    /// Current playhead position in seconds, from the render clock
    /// (PLAN §7 position reporting). Nil when nothing is scheduled.
    func currentPosition() -> Double? {
        guard let file = loadedFile,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        let frames = scheduleStartFrame + playerTime.sampleTime
        let seconds = TimeMath.seconds(forFrames: frames, sampleRate: file.fileFormat.sampleRate)
        return TimeMath.clamp(seconds, min: 0, max: duration)
    }
}
