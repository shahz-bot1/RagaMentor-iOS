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
}
