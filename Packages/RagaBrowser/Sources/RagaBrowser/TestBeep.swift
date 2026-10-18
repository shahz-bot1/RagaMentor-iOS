import Foundation
import AVFoundation

/// The web's 880 Hz test beep (0.18 s sine) on its own engine, so
/// it never disturbs the harmonium pool. Deliberately NOT part of
/// the SequencePlayer core (design §8.2): it is unrelated to
/// sequence playback and moved out of ScalePlayer in P-B.
@MainActor
public final class TestBeep {
    private var engine: AVAudioEngine?

    public init() {}

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
        self.engine = engine
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            engine.stop()
            if self.engine === engine { self.engine = nil }
        }
    }
}
