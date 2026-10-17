import Foundation
import CryptoKit

// Pure, unit-tested core logic (PLAN §13): time math, loop rules,
// group range derivation, waveform peaks, content hashing.
// Nothing here touches AVFoundation or SwiftData, so every rule is
// verifiable in plain XCTest.

enum TimeMath {
    /// Seconds -> frame index at the given sample rate (rounded).
    static func frames(forSeconds seconds: Double, sampleRate: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        return Int64((seconds * sampleRate).rounded())
    }

    /// Frame index -> seconds at the given sample rate.
    static func seconds(forFrames frames: Int64, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(Swift.max(value, lo), hi)
    }
}

enum LoopRules {
    /// Minimum loop length in seconds (PLAN §6).
    static let minLength = 0.3

    /// Normalise a candidate loop against the song duration:
    /// clamps into [0, duration], auto-swaps when end <= start
    /// (PLAN §12: no error alert), then enforces the minimum length
    /// by extending the end (or pulling the start back at the edge).
    /// Returns nil only when the song is too short to hold any loop.
    static func normalize(start rawStart: Double, end rawEnd: Double, duration: Double) -> (start: Double, end: Double)? {
        guard duration >= minLength else { return nil }
        var start = TimeMath.clamp(rawStart, min: 0, max: duration)
        var end = TimeMath.clamp(rawEnd, min: 0, max: duration)
        if end <= start { swap(&start, &end) }
        if end - start < minLength {
            end = start + minLength
            if end > duration {
                end = duration
                start = end - minLength
            }
        }
        return (start, end)
    }

    /// Split a loop at the playhead (PLAN §10 A–B tab). Allowed only when
    /// the playhead is at least minLength inside each end.
    static func canSplit(loopStart: Double, loopEnd: Double, at playhead: Double) -> Bool {
        playhead - loopStart >= minLength && loopEnd - playhead >= minLength
    }

    /// Name for the second piece of a split: "name 2", bumping a trailing
    /// number ("name 2" -> "name 3") and skipping collisions (PLAN §10).
    static func splitSecondName(originalName: String, existingNames: [String]) -> String {
        var base = originalName
        var number = 2
        if let space = originalName.lastIndex(of: " "),
           let n = Int(originalName[originalName.index(after: space)...]) {
            base = String(originalName[..<space])
            number = n + 1
        }
        var candidate = "\(base) \(number)"
        while existingNames.contains(candidate) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }
}

/// A loop's time span, detached from storage, for group range math.
struct LoopSpan {
    let id: UUID
    let start: Double
    let end: Double
}

enum GroupLogic {
    /// Maximum nesting depth: top-level groups may hold sub-groups;
    /// sub-groups hold loops only (PLAN §3 decision 12).
    static let maxDepth = 2

    /// Derived range of a group: earliest descendant loop start to latest
    /// descendant loop end (PLAN §6 — derived bottom-up, never stored).
    /// `children` maps a group id to the ids of its direct members;
    /// `spans` maps a loop id to its span. Returns nil for an empty group.
    static func derivedRange(groupID: UUID,
                             children: [UUID: [UUID]],
                             spans: [UUID: LoopSpan]) -> (start: Double, end: Double)? {
        var result: (start: Double, end: Double)?
        var visited = Set<UUID>()
        func walk(_ id: UUID) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            if let span = spans[id] {
                if let r = result {
                    result = (Swift.min(r.start, span.start), Swift.max(r.end, span.end))
                } else {
                    result = (span.start, span.end)
                }
            }
            for child in children[id] ?? [] { walk(child) }
        }
        for member in children[groupID] ?? [] { walk(member) }
        return result
    }

    /// Depth of an item in the membership tree (loops are depth 0,
    /// a top-level group is depth 1, a sub-group is depth 2).
    /// Used to enforce the cap when reorganising membership.
    static func depth(of itemID: UUID,
                      parent: [UUID: UUID],
                      isGroup: (UUID) -> Bool) -> Int {
        var depth = isGroup(itemID) ? 1 : 0
        var current = itemID
        var guardCount = 0
        while let p = parent[current], guardCount < 64 {
            if isGroup(p) { depth += 1 }
            current = p
            guardCount += 1
        }
        return depth
    }
}

enum Peaks {
    /// Bucket mono samples into `buckets` peak values (max abs per bucket).
    /// The bucket count is fixed so long files cost the same to render
    /// (PLAN §9). Empty input yields all-zero buckets.
    static func bucketize(samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: buckets) }
        var out = [Float](repeating: 0, count: buckets)
        let per = Double(samples.count) / Double(buckets)
        for b in 0..<buckets {
            let lo = Int(Double(b) * per)
            let hi = Swift.min(samples.count, Swift.max(lo + 1, Int(Double(b + 1) * per)))
            var peak: Float = 0
            for i in lo..<hi {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
            out[b] = peak
        }
        return out
    }
}

enum AudioHash {
    /// SHA-256 hex digest of in-memory data (PLAN §3 decision 4).
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Loop playback math (M2, PLAN §7)

enum LoopMath {
    /// Playhead position while a segment loops: the segment start plus the
    /// played frames wrapped into the segment. `playedFrames` counts every
    /// frame the player has consumed since the (re)start of playback.
    static func loopPosition(segmentStartFrame: Int64,
                             segmentFrameCount: Int64,
                             playedFrames: Int64,
                             sampleRate: Double) -> Double {
        guard segmentFrameCount > 0, sampleRate > 0 else {
            return TimeMath.seconds(forFrames: segmentStartFrame, sampleRate: sampleRate)
        }
        let wrapped = playedFrames % segmentFrameCount
        return TimeMath.seconds(forFrames: segmentStartFrame + wrapped, sampleRate: sampleRate)
    }

    /// Whether a segment-completion event should reschedule the loop:
    /// only while loop mode is on and the event belongs to the current
    /// scheduling generation (stale completions after stop/mode changes
    /// are ignored — PLAN §7 gapless re-scheduling).
    static func shouldReschedule(loopEnabled: Bool,
                                 eventGeneration: Int,
                                 currentGeneration: Int) -> Bool {
        loopEnabled && eventGeneration == currentGeneration
    }
}
