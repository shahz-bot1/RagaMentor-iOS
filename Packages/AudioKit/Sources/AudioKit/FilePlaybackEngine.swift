import Foundation
import AVFoundation

/// Playback engine boundary (PARITY-PLAN §3.1, AudioKit).
/// Features talk to this protocol, never to the concrete engine, so
/// view models are testable with fakes. The live implementation is
/// `AudioEngine` (AVAudioEngine + TimePitch, gapless segment looping).
public protocol FilePlaybackEngine: AnyObject {
    /// Playback rate (speed); pitch stays locked in the implementation.
    var rate: Float { get set }
    /// Duration of the loaded file in seconds (0 when nothing is loaded).
    var duration: Double { get }
    var isPlaying: Bool { get }
    var loadedFile: AVAudioFile? { get }
    var loopEnabled: Bool { get }

    func load(url: URL) throws
    /// Arm a loop segment, or clear it with nil values.
    func setLoop(start: Double?, end: Double?)
    func clearLoop()
    func play(from seconds: Double)
    func pause()
    func resume()
    func stop()
    func seek(to seconds: Double)
    /// Playhead position in seconds from the render clock; nil when idle.
    func currentPosition() -> Double?
    /// Offline render of the current schedule (analysis + tests).
    func renderOffline(from seconds: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer?
}
