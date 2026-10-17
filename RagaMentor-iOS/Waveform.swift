import Foundation
import AVFoundation
import SwiftUI

// Waveform support per PLAN §8.6/§9: ~6000 peak buckets per song,
// stored in a sidecar file; geometry (zoom/pan/seek math) is pure and
// unit-tested.

enum PeaksService {
    static let bucketCount = 6000

    /// Sidecar URL next to the audio file: Audio/<hash>.peaks
    static func sidecarURL(for song: Song) -> URL? {
        song.fileURL?.deletingPathExtension().appendingPathExtension("peaks")
    }

    /// Load cached peaks, or compute + cache them.
    static func peaks(for song: Song) async -> [Float] {
        if let url = sidecarURL(for: song),
           let data = try? Data(contentsOf: url),
           data.count == bucketCount * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let fileURL = song.fileURL else { return [] }
        let computed = await Task.detached(priority: .utility) {
            computePeaks(fileURL: fileURL, buckets: bucketCount)
        }.value
        if let url = sidecarURL(for: song), !computed.isEmpty {
            let data = computed.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: .atomic)
        }
        return computed
    }

    /// Stream the file in chunks and fold samples into the bucket grid.
    static func computePeaks(fileURL: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: fileURL),
              file.length > 0 else { return [] }
        let totalFrames = Int(file.length)
        let chunkFrames = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(chunkFrames)) else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        var framesRead = 0
        while framesRead < totalFrames {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(file.processingFormat.channelCount)
            for i in 0..<count {
                var v: Float = 0
                for ch in 0..<channelCount {
                    v = max(v, abs(channels[ch][i]))
                }
                let bucket = min(buckets - 1, (framesRead + i) * buckets / totalFrames)
                if v > peaks[bucket] { peaks[bucket] = v }
            }
            framesRead += count
        }
        return peaks
    }
}

/// Pure geometry for the waveform: a visible time window over the song,
/// with pinch zoom (min window 2 s, PLAN §9) and clamped panning.
struct WaveformWindow: Equatable {
    var start: Double
    var length: Double
    let duration: Double

    init(duration: Double) {
        self.duration = max(duration, 0.01)
        self.start = 0
        self.length = self.duration
    }

    var end: Double { start + length }
    static let minLength = 2.0

    func x(forTime time: Double, width: Double) -> Double {
        guard length > 0, width > 0 else { return 0 }
        return (time - start) / length * width
    }

    func time(forX x: Double, width: Double) -> Double {
        guard length > 0, width > 0 else { return start }
        return TimeMath.clamp(start + x / width * length, min: 0, max: duration)
    }

    /// Zoom by `factor` (< 1 zooms in) around a focal time, clamped to
    /// the 2 s minimum window and the full duration.
    func zoomed(by factor: Double, around focalTime: Double) -> WaveformWindow {
        var w = self
        let newLength = TimeMath.clamp(length * factor, min: Self.minLength, max: duration)
        let focalRatio = length > 0 ? (focalTime - start) / length : 0
        w.length = newLength
        w.start = TimeMath.clamp(focalTime - focalRatio * newLength,
                                 min: 0, max: max(0, duration - newLength))
        return w
    }

    /// Pan so the window's start moves by `deltaSeconds`, clamped.
    func panned(by deltaSeconds: Double) -> WaveformWindow {
        var w = self
        w.start = TimeMath.clamp(start + deltaSeconds, min: 0, max: max(0, duration - length))
        return w
    }

    /// Follow mode: shift the window the minimum amount so `time` is
    /// visible (used while playing in fullscreen, PLAN §9).
    func following(_ time: Double) -> WaveformWindow {
        if time >= start && time <= end { return self }
        var w = self
        if time < start { w.start = max(0, time - length * 0.1) }
        else { w.start = min(max(0, duration - length), time - length * 0.1) }
        return w
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let duration: Double
    let position: Double
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    @Binding var window: WaveformWindow
    var seekEnabled: Bool = true
    var zoomPanEnabled: Bool = false
    var onSeek: (Double) -> Void

    @State private var lastMagnification: CGFloat = 1
    @State private var lastDragX: CGFloat? = nil
    @State private var dragPanned = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { context, size in
                // Loop region tint
                if let ls = loopStart, let le = loopEnd {
                    let x1 = window.x(forTime: ls, width: width)
                    let x2 = window.x(forTime: le, width: width)
                    context.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: size.height)),
                                 with: .color(.accentColor.opacity(0.18)))
                }
                // Bars for the visible bucket range
                if !peaks.isEmpty && duration > 0 {
                    let bucketSpan = Double(peaks.count) / duration
                    let first = max(0, Int(window.start * bucketSpan))
                    let last = min(peaks.count - 1, Int(window.end * bucketSpan))
                    if last >= first {
                        let barWidth = max(1, width / Double(last - first + 1))
                        for b in first...last {
                            let t = Double(b) / bucketSpan
                            let x = window.x(forTime: t, width: width)
                            let h = max(1, Double(peaks[b]) * size.height * 0.92)
                            let rect = CGRect(x: x, y: (size.height - h) / 2,
                                              width: barWidth * 0.72, height: h)
                            context.fill(Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                                         with: .color(.secondary.opacity(0.75)))
                        }
                    }
                }
                // Playhead
                let px = window.x(forTime: position, width: width)
                context.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)),
                             with: .color(.accentColor))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard zoomPanEnabled else { return }
                        if abs(value.translation.width) >= 10 {
                            dragPanned = true
                            if let last = lastDragX {
                                let dx = value.location.x - last
                                let secondsPerPoint = window.length / max(width, 1)
                                window = window.panned(by: -Double(dx) * secondsPerPoint)
                            }
                        }
                        lastDragX = value.location.x
                    }
                    .onEnded { value in
                        defer { lastDragX = nil; dragPanned = false }
                        guard seekEnabled else { return }
                        // A tap (no pan) seeks to that point (PLAN §9).
                        if !dragPanned {
                            onSeek(window.time(forX: value.location.x, width: width))
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        guard zoomPanEnabled else { return }
                        let factor = lastMagnification / scale
                        lastMagnification = scale
                        let focal = window.time(forX: width / 2, width: width)
                        window = window.zoomed(by: factor, around: focal)
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
        }
    }
}
