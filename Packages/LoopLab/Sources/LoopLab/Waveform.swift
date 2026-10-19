import Foundation
import AVFoundation
import SwiftUI
import RagaCore
import AudioKit
import PersistenceKit

// Waveform support per PLAN §8.6/§9: ~6000 peak buckets per song,
// stored in a sidecar file; geometry (zoom/pan/seek math) is pure and
// unit-tested.

/// Song-level peaks cache: a sidecar file next to the audio
/// (Audio/<hash>.peaks). The computation itself is AudioKit's
/// PeaksService; this adds the per-song cache (PLAN §9).
enum SongPeaks {
    /// Sidecar URL next to the audio file: Audio/<hash>.peaks
    static func sidecarURL(for song: Song) -> URL? {
        song.fileURL?.deletingPathExtension().appendingPathExtension("peaks")
    }

    /// Load cached peaks, or compute + cache them.
    static func peaks(for song: Song) async -> [Float] {
        if let url = sidecarURL(for: song),
           let data = try? Data(contentsOf: url),
           data.count == PeaksService.bucketCount * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard let fileURL = song.fileURL else { return [] }
        let computed = await Task.detached(priority: .utility) {
            PeaksService.computePeaks(fileURL: fileURL, buckets: PeaksService.bucketCount)
        }.value
        if let url = sidecarURL(for: song), !computed.isEmpty {
            let data = computed.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: .atomic)
        }
        return computed
    }
}

/// Pure geometry for the waveform: a visible time window over the song,
/// with pinch zoom (min window 2 s, PLAN §9) and clamped panning.
public struct WaveformWindow: Equatable {
    public var start: Double
    public var length: Double
    public let duration: Double

    public init(duration: Double) {
        self.duration = max(duration, 0.01)
        self.start = 0
        self.length = self.duration
    }

    public var end: Double { start + length }
    public static let minLength = 2.0

    public func x(forTime time: Double, width: Double) -> Double {
        guard length > 0, width > 0 else { return 0 }
        return (time - start) / length * width
    }

    public func time(forX x: Double, width: Double) -> Double {
        guard length > 0, width > 0 else { return start }
        return TimeMath.clamp(start + x / width * length, min: 0, max: duration)
    }

    /// Zoom by `factor` (< 1 zooms in) around a focal time, clamped to
    /// the 2 s minimum window and the full duration.
    public func zoomed(by factor: Double, around focalTime: Double) -> WaveformWindow {
        var w = self
        let newLength = TimeMath.clamp(length * factor, min: Self.minLength, max: duration)
        let focalRatio = length > 0 ? (focalTime - start) / length : 0
        w.length = newLength
        w.start = TimeMath.clamp(focalTime - focalRatio * newLength,
                                 min: 0, max: max(0, duration - newLength))
        return w
    }

    /// Fit a range (a loop, or a group's derived span) as large
    /// as possible, centred (v1.5.12 — tapping a loop or group
    /// chip zooms the wave to it): the window takes the range's
    /// length, never below the 2 s floor and never above the
    /// song; centred on the range's midpoint, with the start
    /// clamped at both ends of the song.
    public func fitting(from rangeStart: Double, to rangeEnd: Double) -> WaveformWindow {
        var w = self
        let floor = min(Self.minLength, duration)
        let newLength = TimeMath.clamp(rangeEnd - rangeStart, min: floor, max: duration)
        let centre = (rangeStart + rangeEnd) / 2
        w.length = newLength
        w.start = TimeMath.clamp(centre - newLength / 2,
                                 min: 0, max: max(0, duration - newLength))
        return w
    }

    /// Pan so the window's start moves by `deltaSeconds`, clamped.
    public func panned(by deltaSeconds: Double) -> WaveformWindow {
        var w = self
        w.start = TimeMath.clamp(start + deltaSeconds, min: 0, max: max(0, duration - length))
        return w
    }

    /// Follow mode: shift the window the minimum amount so `time` is
    /// visible (used while playing in fullscreen, PLAN §9).
    public func following(_ time: Double) -> WaveformWindow {
        if time >= start && time <= end { return self }
        var w = self
        if time < start { w.start = max(0, time - length * 0.1) }
        else { w.start = min(max(0, duration - length), time - length * 0.1) }
        return w
    }
}

/// One coloured span under the waveform peaks: a group band or a
/// loop region, the web's paintWave shading model.
struct WaveRegion: Equatable {
    let start: Double
    let end: Double
    let color: Color
    let alpha: Double
}

enum WaveformRegions {
    /// Group bands first (parents before nested groups, lighter
    /// with depth), then every loop tinted with its direct parent
    /// group's colour — accent blue when ungrouped. The selected
    /// loop/group paints strongest. Alphas are the web's exactly.
    static func build(song: Song, selectedLoopID: UUID?,
                      selectedGroupID: UUID?) -> [WaveRegion] {
        let accent = Color(red: 0.357, green: 0.616, blue: 1.0)
        // Direct-parent lookup from membership.
        var parentOf: [UUID: LoopGroup] = [:]
        for group in song.groups {
            for member in group.memberIDs {
                parentOf[member] = group
            }
        }
        func depth(of group: LoopGroup) -> Int {
            var d = 0
            var current: LoopGroup? = group
            var guardCount = 0
            while let c = current, let parent = parentOf[c.id], guardCount < 8 {
                d += 1
                current = parent
                guardCount += 1
            }
            return d
        }
        var regions: [WaveRegion] = []
        for group in song.groups.sorted(by: { depth(of: $0) < depth(of: $1) }) {
            guard let range = LoopsView.derivedRange(of: group, song: song) else { continue }
            let selected = group.id == selectedGroupID
            let alpha = selected ? 0.30 : max(0.07, 0.13 - Double(depth(of: group)) * 0.05)
            regions.append(WaveRegion(start: range.start, end: range.end,
                                      color: Color(hex: group.colorHex), alpha: alpha))
        }
        for loop in song.loops {
            let selected = loop.id == selectedLoopID
            if let parent = parentOf[loop.id] {
                regions.append(WaveRegion(start: loop.start, end: loop.end,
                                          color: Color(hex: parent.colorHex),
                                          alpha: selected ? 0.45 : 0.20))
            } else {
                regions.append(WaveRegion(start: loop.start, end: loop.end,
                                          color: accent,
                                          alpha: selected ? 0.30 : 0.12))
            }
        }
        return regions
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let duration: Double
    let position: Double
    var loopStart: Double? = nil
    var loopEnd: Double? = nil
    /// Coloured spans (group bands + loop regions) under the peaks.
    var regions: [WaveRegion] = []
    @Binding var window: WaveformWindow
    var seekEnabled: Bool = true
    var zoomPanEnabled: Bool = false
    var onSeek: (Double) -> Void

    @State private var lastMagnification: CGFloat = 1
    @State private var lastDragX: CGFloat? = nil
    @State private var dragPanned = false

    var body: some View {
        GeometryReader { geo in
            let width = Double(geo.size.width)
            Canvas { context, size in
                let height = Double(size.height)
                // Coloured spans: group bands + loop regions (web model)
                for region in regions {
                    let x1 = window.x(forTime: region.start, width: width)
                    let x2 = window.x(forTime: region.end, width: width)
                    context.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: height)),
                                 with: .color(region.color.opacity(region.alpha)))
                }
                // Loop region tint
                if let ls = loopStart, let le = loopEnd {
                    let x1 = window.x(forTime: ls, width: width)
                    let x2 = window.x(forTime: le, width: width)
                    context.fill(Path(CGRect(x: x1, y: 0, width: max(1, x2 - x1), height: height)),
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
                            let h = max(1, Double(peaks[b]) * height * 0.92)
                            let rect = CGRect(x: x, y: (height - h) / 2,
                                              width: barWidth * 0.72, height: h)
                            context.fill(Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                                         with: .color(.secondary.opacity(0.75)))
                        }
                    }
                }
                // Playhead
                let px = window.x(forTime: position, width: width)
                context.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: height)),
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
                            onSeek(window.time(forX: Double(value.location.x), width: width))
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
