import AVFoundation
import Foundation

/// A lookahead-scheduled click source for Tala Studio: sine clicks
/// with the web voice (exponential decay to 0.001 at +0.06 s, cut
/// at +0.09 s), placed on the engine's sample timeline so the
/// 25 ms / 0.15 s lookahead scheduler stays sample-accurate.
public protocol ClickEngine: AnyObject {
    /// Start the engine (idempotent).
    func prepare()
    /// The engine's current frame on its output timeline.
    var currentFrame: Int64 { get }
    var sampleRate: Double { get }
    /// Schedule one click at an absolute frame.
    func scheduleClick(atFrame frame: Int64, frequency: Double, gain: Float)
    /// Drop every scheduled click (stop).
    func clear()
}

/// Click storage shared between the scheduler thread and the
/// render thread.
private final class ClickQueue: @unchecked Sendable {
    struct Click {
        let start: Int64
        let frequency: Double
        let gain: Float
    }
    private let lock = NSLock()
    private var clicks: [Click] = []

    func add(_ click: Click) {
        lock.lock()
        clicks.append(click)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        clicks = []
        lock.unlock()
    }

    /// Snapshot for a render pass starting at `frame`; prunes
    /// clicks that ended before it.
    func snapshot(from frame: Int64, horizon: Int64) -> [Click] {
        lock.lock()
        clicks.removeAll { $0.start + horizon < frame }
        let copy = clicks
        lock.unlock()
        return copy
    }
}

public final class SineClickEngine: ClickEngine {
    private let engine = AVAudioEngine()
    private let queue = ClickQueue()
    private var started = false

    public init() {}

    public var sampleRate: Double {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return sr > 0 ? sr : 48000
    }

    public var currentFrame: Int64 {
        guard let time = engine.outputNode.lastRenderTime,
              time.isSampleTimeValid else { return 0 }
        return time.sampleTime
    }

    public func prepare() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let format = engine.outputNode.outputFormat(forBus: 0)
        let sr = format.sampleRate > 0 ? format.sampleRate : 48000
        let queue = self.queue
        let source = AVAudioSourceNode {
            _, timestamp, frameCount, audioBufferList -> OSStatus in
            // The timestamp's sample time is the exact frame this
            // buffer starts at on the engine timeline — the same
            // timeline `currentFrame` reports.
            let base = Int64(timestamp.pointee.mSampleTime)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            return SineClickEngine.render(queue: queue, abl: abl, base: base,
                                          frames: Int(frameCount), sampleRate: sr)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            engine.prepare()
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    public func scheduleClick(atFrame frame: Int64, frequency: Double, gain: Float) {
        queue.add(ClickQueue.Click(start: frame, frequency: frequency, gain: gain))
    }

    public func clear() {
        queue.clear()
    }

    private static func render(queue: ClickQueue,
                               abl: UnsafeMutableAudioBufferListPointer,
                               base: Int64, frames: Int,
                               sampleRate: Double) -> OSStatus {
        let horizon = Int64(0.09 * sampleRate) + 1
        let active = queue.snapshot(from: base, horizon: horizon)
        for frame in 0..<frames {
            let now = base + Int64(frame)
            var value: Float = 0
            for click in active {
                let ageFrames = now - click.start
                if ageFrames < 0 || ageFrames >= horizon { continue }
                let age = Double(ageFrames) / sampleRate
                // Exponential decay reaching 0.001 at +0.06 s, then
                // held at that floor until the +0.09 s cut (the web
                // oscillator + gain shape).
                let level: Double
                if age <= 0.06 {
                    level = Double(click.gain)
                        * pow(0.001 / Double(click.gain), age / 0.06)
                } else {
                    level = 0.001
                }
                value += Float(level * sin(2 * Double.pi * click.frequency * age))
            }
            for buffer in abl {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                data[frame] = value
            }
        }
        return noErr
    }
}
