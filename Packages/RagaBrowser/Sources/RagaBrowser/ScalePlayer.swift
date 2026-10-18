import Foundation
import AVFoundation
import AudioKit

/// Scale playback for the RagaBrowser detail (web Listen card): all
/// notes scheduled up front on the harmonium tone engine, with the
/// web's note duration (step × (1 + min(1.5, 0.075/step))) and a
/// per-note highlight index. Also owns the 880 Hz test beep.
@MainActor
public final class ScalePlayer: ObservableObject {
    @Published public private(set) var currentIndex: Int = -1
    @Published public private(set) var isPlaying = false
    /// False until the samples report ready (the status line).
    @Published public private(set) var samplesReady = false

    private let tone: any ToneEngine
    private var generation = 0
    private var tasks: [Task<Void, Never>] = []
    private var beepEngine: AVAudioEngine?

    public init(tone: any ToneEngine = HarmoniumToneEngine()) {
        self.tone = tone
    }

    /// Play absolute semitones (Sa offset already applied) at the
    /// given tempo; one step per note.
    public func play(semitones: [Int], tempo: Int) {
        stop()
        generation += 1
        let gen = generation
        isPlaying = true
        let step = 60.0 / Double(tempo)
        let duration = step * (1 + min(1.5, 0.075 / step))
        Task {
            await tone.prepare()
            samplesReady = tone.samplesReady
            guard gen == generation else { return }
            for (index, semitone) in semitones.enumerated() {
                tone.playNote(semitone: semitone,
                              atOffset: 0.1 + Double(index) * step,
                              duration: duration)
            }
            for (index, _) in semitones.enumerated() {
                tasks.append(Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64((0.1 + Double(index) * step) * 1_000_000_000))
                    if gen == generation { currentIndex = index }
                })
            }
            tasks.append(Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((0.1 + Double(semitones.count) * step + 0.3) * 1_000_000_000))
                if gen == generation { finish() }
            })
        }
    }

    public func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        tone.stopAll()
        finish()
    }

    private func finish() {
        isPlaying = false
        currentIndex = -1
    }

    /// The web's 880 Hz test beep (0.15 s sine), on its own engine so
    /// it never disturbs the harmonium pool.
    public func beep() {
        let engine = AVAudioEngine()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        var phase: Double = 0
        let increment = 2 * Double.pi * 880 / format.sampleRate
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(phase) * 0.3)
                phase += increment
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        beepEngine = engine
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            engine.stop()
            if beepEngine === engine { beepEngine = nil }
        }
    }
}
