import AVFoundation
import Foundation
import RagaCore

/// Short-note playback (swara phrases now; RagaBrowser and Varisai
/// later): harmonium samples with the sustain renderer, triangle synth
/// fallback when a sample is unavailable (web StudioAudio parity).
public protocol ToneEngine: AnyObject {
    var samplesReady: Bool { get }
    func prepare() async
    /// Schedule one note: semitone relative to C4, starting `offset`
    /// seconds from now, with sounded duration `duration` seconds
    /// (the caller applies the phrase rule soundDur = slice +
    /// min(0.28, slice × 0.7)).
    func playNote(semitone: Int, atOffset offset: Double, duration: Double)
    func stopAll()
}

public final class HarmoniumToneEngine: ToneEngine {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var engineStarted = false
    /// The format the players are connected with. Every scheduled
    /// buffer is rendered into exactly this format: AVAudioPlayerNode
    /// crashes when a buffer's format differs from its connection
    /// format (the bundled samples are 44.1 kHz mono; a device's
    /// hardware format is usually 48 kHz stereo — connecting with a
    /// nil format and scheduling sample-format buffers crashed phrase
    /// playback on device, v0.8.0).
    private var nodeFormat: AVAudioFormat?
    private var buffers: [String: AVAudioPCMBuffer] = [:] // file name → sample
    private var renderCache: [String: AVAudioPCMBuffer] = [:]
    public private(set) var samplesReady = false

    public init(playerCount: Int = 4) {
        for _ in 0..<playerCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            players.append(node)
        }
    }

    public func prepare() async {
        if samplesReady { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: AVAudioPCMBuffer] in
            var out: [String: AVAudioPCMBuffer] = [:]
            for semi in SampleMap.availableSemitones {
                let name = SampleMap.fileName(forAvailableSemitone: semi)
                guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                                  subdirectory: "Harmonium")
                    ?? Bundle.module.url(forResource: name, withExtension: nil),
                      let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length))
                else { continue }
                do {
                    try file.read(into: buffer)
                    out[name] = buffer
                } catch { continue }
            }
            return out
        }.value
        await MainActor.run {
            buffers = loaded
            samplesReady = !loaded.isEmpty
        }
    }

    private func ensureEngine() {
        if engineStarted { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        if nodeFormat == nil {
            let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            nodeFormat = mixerFormat.sampleRate > 0
                ? mixerFormat
                : AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            for player in players {
                engine.connect(player, to: engine.mainMixerNode, format: nodeFormat)
            }
        }
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
        } catch {
            engineStarted = false
        }
    }

    public func playNote(semitone: Int, atOffset offset: Double, duration: Double) {
        ensureEngine()
        guard engineStarted, let format = nodeFormat else { return }
        let rendered: AVAudioPCMBuffer?
        let cacheKey = "\(semitone)|\(Int((duration * 20).rounded()))"
        if let cached = renderCache[cacheKey] {
            rendered = cached
        } else {
            let (file, rate) = SampleMap.sample(forSemitone: semitone)
            if let source = buffers[file] {
                rendered = SustainRenderer.render(
                    source: source, rate: rate, duration: duration,
                    outputSampleRate: format.sampleRate,
                    outputChannels: Int(format.channelCount))
            } else {
                rendered = SustainRenderer.renderSynth(
                    frequency: 261.63 * pow(2, Double(semitone) / 12),
                    duration: duration,
                    sampleRate: format.sampleRate,
                    channels: Int(format.channelCount))
            }
            if let rendered { renderCache[cacheKey] = rendered }
        }
        guard let buffer = rendered else { return }
        let player = players[nextPlayer % players.count]
        nextPlayer += 1
        if !player.isPlaying { player.play() }
        if offset > 0.001,
           let renderTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: renderTime) {
            let target = playerTime.sampleTime +
                AVAudioFramePosition(offset * playerTime.sampleRate)
            player.scheduleBuffer(buffer,
                                  at: AVAudioTime(sampleTime: target, atRate: playerTime.sampleRate),
                                  options: [])
        } else {
            player.scheduleBuffer(buffer, at: nil, options: [])
        }
    }

    public func stopAll() {
        for player in players {
            player.stop()
        }
        nextPlayer = 0
    }
}
