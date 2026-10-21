import XCTest
import AVFoundation
import AudioKit

// AudioKit tests (PARITY-PLAN §6: the v0.6.0 suite, split per module in P0).
final class AudioKitTests: XCTestCase {

    private func makeSineFile(segments: [(freq: Double, seconds: Double)],
                              sampleRate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let totalFrames = segments.reduce(0) { $0 + Int($1.seconds * sampleRate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))!
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let data = buffer.floatChannelData![0]
        var frame = 0
        for seg in segments {
            let count = Int(seg.seconds * sampleRate)
            for i in 0..<count {
                data[frame + i] = Float(0.5 * sin(2 * Double.pi * seg.freq * Double(i) / sampleRate))
            }
            frame += count
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func rms(_ buffer: AVAudioPCMBuffer, from: Int, count: Int) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var sum = 0.0
        for i in from..<(from + count) {
            sum += Double(data[i]) * Double(data[i])
        }
        return count > 0 ? sqrt(sum / Double(count)) : 0
    }

    private func zeroCrossings(_ buffer: AVAudioPCMBuffer, from: Int, count: Int) -> Int {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var crossings = 0
        for i in (from + 1)..<(from + count) where (data[i - 1] < 0) != (data[i] < 0) {
            crossings += 1
        }
        return crossings
    }

    func testOfflineRenderProducesAudio() throws {
        let url = try makeSineFile(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        try engine.load(url: url)
        let out = try XCTUnwrap(engine.renderOffline(from: 0, frames: 22050))
        XCTAssertEqual(Int(out.frameLength), 22050)
        XCTAssertGreaterThan(rms(out, from: 0, count: 22050), 0.1)
    }

    func testOfflineRenderLoopRepeatsSegment() throws {
        // 0.5s of 440 Hz then 0.5s of 880 Hz. Loop the 440 half only:
        // 1.5s of render must stay 440-ish (zero-crossing rate), proving
        // the completion-driven re-scheduling actually loops.
        let url = try makeSineFile(segments: [(440, 0.5), (880, 0.5)])
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        try engine.load(url: url)
        engine.setLoop(start: 0, end: 0.5)
        let half = 22050
        let out = try XCTUnwrap(engine.renderOffline(from: 0, frames: AVAudioFrameCount(half * 3)))
        XCTAssertEqual(Int(out.frameLength), half * 3)
        for chunkIndex in 0..<3 {
            XCTAssertGreaterThan(rms(out, from: chunkIndex * half, count: half), 0.1,
                                 "chunk \(chunkIndex) should have audio")
        }
        let zc1 = zeroCrossings(out, from: 0, count: half)
        let zc3 = zeroCrossings(out, from: 2 * half, count: half)
        XCTAssertGreaterThan(zc1, 300) // ~440 crossings for 0.5s of 440 Hz
        // Third pass matches the first pass, and is well below what
        // 880 Hz material would produce (~880 crossings).
        XCTAssertEqual(Double(zc3), Double(zc1), accuracy: Double(zc1) * 0.35)
        XCTAssertLessThan(zc3, Int(Double(zc1) * 1.6))
    }

    func testOfflineRenderRateStretches() throws {
        // 0.5s sine + 0.5s silence. At rate 1 the rendered second half is
        // silent; at 0.5x the sine stretches across the whole second.
        let url = try makeSineFile(segments: [(440, 0.5), (0, 0.5)])
        defer { try? FileManager.default.removeItem(at: url) }

        let half = 22050
        let engine1 = AudioEngine()
        try engine1.load(url: url)
        let out1 = try XCTUnwrap(engine1.renderOffline(from: 0, frames: AVAudioFrameCount(half * 2)))
        XCTAssertGreaterThan(rms(out1, from: 0, count: half), 0.1)
        XCTAssertLessThan(rms(out1, from: half, count: half), 0.02)

        let engine2 = AudioEngine()
        try engine2.load(url: url)
        engine2.rate = 0.5
        let out2 = try XCTUnwrap(engine2.renderOffline(from: 0, frames: AVAudioFrameCount(half * 2)))
        XCTAssertGreaterThan(rms(out2, from: half, count: half), 0.05,
                             "at 0.5x the sine should still be sounding in the second half")
    }

    func testComputePeaksFromFile() throws {
        let url = try makeSineFile(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = PeaksService.computePeaks(fileURL: url, buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        // A 0.5-amplitude sine peaks near 0.5 in every bucket.
        XCTAssertTrue(peaks.allSatisfy { $0 > 0.4 && $0 <= 0.51 })
    }

    // MARK: - P1: sample map + sustain renderer

    func testSampleMapNearestAndRate() {
        XCTAssertEqual(SampleMap.sample(forSemitone: 0).fileName, "C4.mp3")
        XCTAssertEqual(SampleMap.sample(forSemitone: 0).rate, 1)
        XCTAssertEqual(SampleMap.sample(forSemitone: 11).fileName, "B4.mp3")
        XCTAssertEqual(SampleMap.sample(forSemitone: 12).fileName, "C5.mp3")
        // F#4 has no sample: F4 shifted up a semitone (first wins the tie).
        let fs = SampleMap.sample(forSemitone: 6)
        XCTAssertEqual(fs.fileName, "F4.mp3")
        XCTAssertEqual(fs.rate, pow(2, 1.0 / 12), accuracy: 1e-9)
        // Below C4 and above C5 ride the edge samples.
        XCTAssertEqual(SampleMap.sample(forSemitone: -1).fileName, "C4.mp3")
        XCTAssertEqual(SampleMap.sample(forSemitone: -1).rate, pow(2, -1.0 / 12), accuracy: 1e-9)
        XCTAssertEqual(SampleMap.sample(forSemitone: 13).fileName, "C5.mp3")
        XCTAssertEqual(SampleMap.sample(forSemitone: 13).rate, pow(2, 1.0 / 12), accuracy: 1e-9)
    }

    func testCrossfadeGainsAreEqualPower() {
        // The perceptual quantity the web suite asserts: fadeIn² + fadeOut²
        // stays 1 across the whole crossfade (no dip, no swell).
        for i in 0...20 {
            let phase = Double(i) / 20
            let g = SustainRenderer.crossfadeGains(phase: phase)
            XCTAssertEqual(g.fadeIn * g.fadeIn + g.fadeOut * g.fadeOut, 1, accuracy: 1e-9,
                           "phase \(phase)")
        }
    }

    func testMasterEnvelopeShape() {
        XCTAssertEqual(SustainRenderer.masterEnvelope(at: 0.02, duration: 2), 0.9, accuracy: 1e-6)
        XCTAssertEqual(SustainRenderer.masterEnvelope(at: 1, duration: 2), 0.9, accuracy: 1e-6)
        XCTAssertEqual(SustainRenderer.masterEnvelope(at: 2.15, duration: 2), 0.0001, accuracy: 1e-6)
        XCTAssertLessThan(SustainRenderer.masterEnvelope(at: 0.01, duration: 2), 0.9)
    }

    func testMasterEnvelopeHoldsLevelIntoTheNextNote() {
        // The perceptual pin for the settled envelope (v1.5.16):
        // when the next swara attacks one step (1 s) into a note,
        // the outgoing note must still be near its sustain level —
        // the old exponential release had already dived to ~0.2
        // by then, which read as a pause between notes. The
        // cosine release over the same 0.12 s span stays up.
        XCTAssertGreaterThanOrEqual(
            SustainRenderer.masterEnvelope(at: 1.0, duration: 1.075), 0.55)
        XCTAssertGreaterThanOrEqual(
            SustainRenderer.masterEnvelope(at: 1.0, duration: 1.30), 0.8)
        // And the release does end: by duration + tail it is done.
        XCTAssertEqual(SustainRenderer.masterEnvelope(at: 1.45, duration: 1.30),
                       0.0001, accuracy: 1e-6)
    }

    private func sineBuffer(seconds: Double, freq: Double = 100,
                            sampleRate: Double = 8000, amplitude: Double = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = Float(amplitude * sin(2 * Double.pi * freq * Double(i) / sampleRate))
        }
        return buffer
    }

    private func windowRMS(_ buffer: AVAudioPCMBuffer, from: Double, to: Double, channel: Int = 0) -> Double {
        let sr = buffer.format.sampleRate
        let data = buffer.floatChannelData![channel]
        let a = Int(from * sr), b = min(Int(to * sr), Int(buffer.frameLength))
        var sum = 0.0
        for i in a..<b { sum += Double(data[i]) * Double(data[i]) }
        return sqrt(sum / Double(max(1, b - a)))
    }

    func testSustainRenderHoldsLevelWithoutDip() {
        // 4 s sample (chain path: bd > 2.5), note held 6 s. The
        // property the equal-power chain guarantees — and the one the
        // web's exponential-ramp bug broke — is NO DIP: crossfading
        // copies can never collapse the level (fadeIn² + fadeOut² = 1).
        // With a pure sine the looped copies are phase-coherent, so
        // the summed level may swell toward the sin+cos bound (√2×);
        // real samples are decorrelated and hold level. Assert the
        // honest envelope: never below 0.75×, never above 1.45×.
        let source = sineBuffer(seconds: 4)
        let rendered = try! XCTUnwrap(SustainRenderer.render(source: source, rate: 1, duration: 6))
        let expected = 0.5 / sqrt(2) * 0.9
        for window in [(1.0, 2.0), (2.0, 3.0), (3.0, 4.0), (4.0, 5.0), (5.0, 5.8)] {
            let rms = windowRMS(rendered, from: window.0, to: window.1)
            XCTAssertTrue(rms > expected * 0.75 && rms < expected * 1.45,
                          "window \(window) out of bounds: \(rms) vs \(expected)")
        }
    }

    func testSustainRenderConvertsToNodeFormat() {
        // The device crash this guards (v0.8.0): the samples are
        // 44.1 kHz mono, the player node's connection format is the
        // hardware format (48 kHz stereo here) — a scheduled buffer
        // MUST be rendered in the node format or scheduleBuffer
        // crashes. Render an 8 kHz mono source into 48 kHz stereo.
        let source = sineBuffer(seconds: 4)
        let rendered = try! XCTUnwrap(SustainRenderer.render(
            source: source, rate: 1, duration: 1,
            outputSampleRate: 48000, outputChannels: 2))
        XCTAssertEqual(rendered.format.sampleRate, 48000)
        XCTAssertEqual(rendered.format.channelCount, 2)
        XCTAssertEqual(Double(rendered.frameLength) / 48000, 1.2, accuracy: 0.01)
        // The mono source feeds BOTH channels with real signal.
        let expected = 0.5 / sqrt(2) * 0.9
        XCTAssertEqual(windowRMS(rendered, from: 0.2, to: 0.8, channel: 0), expected, accuracy: expected * 0.1)
        XCTAssertEqual(windowRMS(rendered, from: 0.2, to: 0.8, channel: 1), expected, accuracy: expected * 0.1)
    }

    func testSustainRenderSingleSourcePath() {
        // A note that fits inside the sample plays as a single pass.
        let source = sineBuffer(seconds: 4)
        let rendered = try! XCTUnwrap(SustainRenderer.render(source: source, rate: 1, duration: 1))
        let expected = 0.5 / sqrt(2) * 0.9
        XCTAssertEqual(windowRMS(rendered, from: 0.2, to: 0.8), expected, accuracy: expected * 0.1)
        // Output length follows the web stop time (dur + 0.2 s).
        XCTAssertEqual(Double(rendered.frameLength) / 8000, 1.2, accuracy: 0.01)
    }
}

extension AudioKitTests {
    /// The realtime loop queue (v1.5.31): a 0.4 s loop played
    /// for ~2.2 s of wall time must keep wrapping inside its
    /// segment — the reported position never escapes, never
    /// stalls, and wraps repeatedly. Seam sample-exactness is
    /// by construction (queued segments play back to back);
    /// this guards the mechanics: the queue stays alive and
    /// the modulo position stays glued to the segment.
    func testRealtimeLoopStaysInSegmentAndWraps() async throws {
        let url = try makeSineFile(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        try engine.load(url: url)
        engine.setLoop(start: 0.2, end: 0.6)
        engine.play(from: 0.2)
        defer { engine.stop() }

        // Skip the first 0.25 s: at start-up the render clock
        // lags the schedule by about a buffer, so the reported
        // position can sit a few tens of ms before the entry
        // point transiently (pre-existing readout behaviour).
        try await Task.sleep(nanoseconds: 250_000_000)
        var samples: [Double] = []
        let deadline = Date().addingTimeInterval(2.2)
        while Date() < deadline {
            if let p = engine.currentPosition() { samples.append(p) }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertGreaterThan(samples.count, 15,
                             "position must keep reporting during loop playback")
        for p in samples {
            XCTAssertTrue(p >= 0.15 && p <= 0.65,
                          "position escaped the loop segment: \(p)")
        }
        var wraps = 0
        for (a, b) in zip(samples, samples.dropFirst()) where a - b > 0.2 {
            wraps += 1
        }
        XCTAssertGreaterThanOrEqual(wraps, 3,
                                    "expected several clean wraps, got \(wraps)")
    }
}

extension AudioKitTests {
    private func waitUntil(_ seconds: Double = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// The output gate (v1.5.35): transport actions drive it —
    /// pause and a paused seek end gated (the TimePitch tail is
    /// silenced), play opens it. The ramp lands within ~10 ms;
    /// these assert the states and the settled volumes.
    func testGateFollowsTransport() throws {
        let url = try makeSineFile(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        try engine.load(url: url)

        engine.play(from: 0)
        XCTAssertTrue(engine.gateOpen)
        engine.pause()
        XCTAssertFalse(engine.gateOpen, "pause must close the gate")
        XCTAssertTrue(waitUntil { engine.gateVolume == 0 },
                      "the gate volume must settle at 0 after pause")

        engine.play(from: 0)
        XCTAssertTrue(engine.gateOpen, "play must open the gate")
        XCTAssertTrue(waitUntil { engine.gateVolume == 1 },
                      "the gate volume must settle at 1 after play")

        engine.pause()
        _ = waitUntil { engine.gateVolume == 0 }
        engine.seek(to: 0.3)
        XCTAssertFalse(engine.gateOpen,
                       "a seek while paused must end with the gate closed")
        engine.stop()
    }

    /// The offline render pulls through the gate: it must force
    /// the gate open while rendering (a paused engine must not
    /// render silence) and restore the closed gate afterwards.
    func testOfflineRenderIgnoresClosedGate() throws {
        let url = try makeSineFile(segments: [(440, 1.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AudioEngine()
        try engine.load(url: url)
        engine.play(from: 0)
        engine.pause()
        XCTAssertFalse(engine.gateOpen)

        let out = try XCTUnwrap(engine.renderOffline(from: 0, frames: 22050))
        XCTAssertGreaterThan(rms(out, from: 0, count: 22050), 0.1,
                             "the render must not be silenced by the closed gate")
        XCTAssertFalse(engine.gateOpen,
                       "the render must restore the prior gate state")
    }
}
