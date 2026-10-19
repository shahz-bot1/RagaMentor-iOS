import Foundation
import CryptoKit

// RagaCore: pure domain logic for the whole suite (PARITY-PLAN §3.1).
// No UI, no audio, no storage — every rule here is unit-testable.

// Pure, unit-tested core logic (PLAN §13): time math, loop rules,
// group range derivation, waveform peaks, content hashing.
// Nothing here touches AVFoundation or SwiftData, so every rule is
// verifiable in plain XCTest.

public enum TimeMath {
    /// Seconds -> frame index at the given sample rate (rounded).
    public static func frames(forSeconds seconds: Double, sampleRate: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        return Int64((seconds * sampleRate).rounded())
    }

    /// Frame index -> seconds at the given sample rate.
    public static func seconds(forFrames frames: Int64, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    public static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(Swift.max(value, lo), hi)
    }
}

public enum LoopRules {
    /// Minimum loop length in seconds (PLAN §6).
    public static let minLength = 0.3

    /// Normalise a candidate loop against the song duration:
    /// clamps into [0, duration], auto-swaps when end <= start
    /// (PLAN §12: no error alert), then enforces the minimum length
    /// by extending the end (or pulling the start back at the edge).
    /// Returns nil only when the song is too short to hold any loop.
    public static func normalize(start rawStart: Double, end rawEnd: Double, duration: Double) -> (start: Double, end: Double)? {
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
    public static func canSplit(loopStart: Double, loopEnd: Double, at playhead: Double) -> Bool {
        playhead - loopStart >= minLength && loopEnd - playhead >= minLength
    }

    /// Name for the second piece of a split: "name 2", bumping a trailing
    /// number ("name 2" -> "name 3") and skipping collisions (PLAN §10).
    public static func splitSecondName(originalName: String, existingNames: [String]) -> String {
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
public struct LoopSpan {
    public let id: UUID
    public let start: Double
    public let end: Double

    public init(id: UUID, start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public enum GroupLogic {
    /// Maximum nesting depth: top-level groups may hold sub-groups;
    /// sub-groups hold loops only (PLAN §3 decision 12).
    public static let maxDepth = 2

    /// Derived range of a group: earliest descendant loop start to latest
    /// descendant loop end (PLAN §6 — derived bottom-up, never stored).
    /// `children` maps a group id to the ids of its direct members;
    /// `spans` maps a loop id to its span. Returns nil for an empty group.
    public static func derivedRange(groupID: UUID,
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
    public static func depth(of itemID: UUID,
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

// MARK: - Group membership operations (M3, PLAN §3/§6)

/// A group's membership as plain data, for pure transformations.
public struct GroupData: Equatable {
    public var id: UUID
    public var memberIDs: [UUID]

    public init(id: UUID, memberIDs: [UUID]) {
        self.id = id
        self.memberIDs = memberIDs
    }
}

public enum GroupOps {
    /// group id -> parent group id, from all groups' member lists.
    public static func parentMap(groups: [GroupData]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for g in groups {
            for member in g.memberIDs { map[member] = g.id }
        }
        return map
    }

    /// All loop ids under a group, directly or through sub-groups.
    public static func descendantLoopIDs(of groupID: UUID,
                                  groups: [GroupData],
                                  loopIDs: Set<UUID>) -> [UUID] {
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var out: [UUID] = []
        var visited = Set<UUID>()
        func walk(_ id: UUID) {
            guard !visited.contains(id) else { return }
            visited.insert(id)
            if loopIDs.contains(id) { out.append(id); return }
            for member in byID[id]?.memberIDs ?? [] { walk(member) }
        }
        for member in byID[groupID]?.memberIDs ?? [] { walk(member) }
        return out
    }

    /// Ids of groups with no descendant loops. Such groups vanish
    /// automatically, cascading upward (PLAN §6).
    public static func emptyGroupIDs(groups: [GroupData], loopIDs: Set<UUID>) -> Set<UUID> {
        var empty = Set<UUID>()
        var remaining = groups
        var changed = true
        while changed {
            changed = false
            for g in remaining where !empty.contains(g.id) {
                if descendantLoopIDs(of: g.id, groups: remaining, loopIDs: loopIDs).isEmpty {
                    empty.insert(g.id)
                    remaining.removeAll { $0.id == g.id }
                    changed = true
                }
            }
        }
        return empty
    }

    /// memberIDs sorted by start time: loops by their span start,
    /// groups by their derived range start (PLAN §6). Ties put loops
    /// before groups, then break by id for determinism.
    public static func sortedMemberIDs(_ memberIDs: [UUID],
                                groups: [GroupData],
                                spans: [UUID: LoopSpan]) -> [UUID] {
        let children = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.memberIDs) })
        let groupIDs = Set(groups.map(\.id))
        func start(of id: UUID) -> Double {
            if let span = spans[id] { return span.start }
            return GroupLogic.derivedRange(groupID: id, children: children, spans: spans)?.start ?? .greatestFiniteMagnitude
        }
        return memberIDs.sorted { a, b in
            let (sa, sb) = (start(of: a), start(of: b))
            if sa != sb { return sa < sb }
            let (ga, gb) = (groupIDs.contains(a), groupIDs.contains(b))
            if ga != gb { return !ga } // loops first
            return a.uuidString < b.uuidString
        }
    }

    /// Delete a group: its children are promoted to the deleted group's
    /// parent (or the top level), per PLAN §6.
    public static func deletingGroup(_ groupID: UUID, from groups: [GroupData]) -> [GroupData] {
        guard let target = groups.first(where: { $0.id == groupID }) else { return groups }
        let parent = parentMap(groups: groups)[groupID]
        var out = groups.filter { $0.id != groupID }
        if let parent, let idx = out.firstIndex(where: { $0.id == parent }) {
            var members = out[idx].memberIDs.filter { $0 != groupID }
            members.append(contentsOf: target.memberIDs)
            out[idx].memberIDs = members
        }
        return out
    }

    /// Set a group's membership to exactly `newMembers` (the checklist
    /// model, PLAN §3 decision 12): members are first removed from any
    /// other group that held them, then the target list is replaced.
    public static func settingMembers(of groupID: UUID,
                               to newMembers: [UUID],
                               in groups: [GroupData]) -> [GroupData] {
        var out = groups.map { g -> GroupData in
            var g = g
            if g.id != groupID {
                g.memberIDs.removeAll { newMembers.contains($0) }
            }
            return g
        }
        if let idx = out.firstIndex(where: { $0.id == groupID }) {
            out[idx].memberIDs = newMembers
        }
        return out
    }
}

// MARK: - Loops backup (M4, PLAN §11; format v3 since P1)

/// The backup layer's shared vocabulary (snapshots in, planned import
/// out). The file format itself is v3 only — see LoopsBackupV3. The
/// short-lived native v1 format was retired in P1 (user decision,
/// 2026-10-17): one platform-independent JSON, identical to the web's.
public enum LoopsBackup {
    /// A loop/group as the backup layer sees it (storage-agnostic).
    public struct LoopRegionSnapshot {
        public var id: UUID
        public var name: String
        public var note: String
        public var start: Double
        public var end: Double
        public var phrase: Phrase?

        public init(id: UUID, name: String, note: String, start: Double, end: Double,
                    phrase: Phrase? = nil) {
            self.id = id
            self.name = name
            self.note = note
            self.start = start
            self.end = end
            self.phrase = phrase
        }
    }
    public struct LoopGroupSnapshot {
        public var id: UUID
        public var name: String
        public var colorHex: String
        public var memberIDs: [UUID]

        public init(id: UUID, name: String, colorHex: String, memberIDs: [UUID]) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
            self.memberIDs = memberIDs
        }
    }

    /// Planned import result with fresh DB ids minted.
    public struct PlannedLoop {
        public var id: UUID; public var name: String; public var note: String
        public var start: Double; public var end: Double; public var phrase: Phrase? = nil
        public init(id: UUID, name: String, note: String, start: Double, end: Double,
                    phrase: Phrase? = nil) {
            self.id = id; self.name = name; self.note = note
            self.start = start; self.end = end; self.phrase = phrase
        }
    }
    public struct PlannedGroup {
        public var id: UUID; public var name: String; public var colorHex: String
        public var memberIDs: [UUID]
        public init(id: UUID, name: String, colorHex: String, memberIDs: [UUID]) {
            self.id = id; self.name = name; self.colorHex = colorHex; self.memberIDs = memberIDs
        }
    }

}

public enum Peaks {
    /// Bucket mono samples into `buckets` peak values (max abs per bucket).
    /// The bucket count is fixed so long files cost the same to render
    /// (PLAN §9). Empty input yields all-zero buckets.
    public static func bucketize(samples: [Float], buckets: Int) -> [Float] {
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

public enum AudioHash {
    /// SHA-256 hex digest of in-memory data (PLAN §3 decision 4).
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Loop playback math (M2, PLAN §7)

public enum LoopMath {
    /// Playhead position while a segment loops: the segment start plus the
    /// played frames wrapped into the segment. `playedFrames` counts every
    /// frame the player has consumed since the (re)start of playback.
    public static func loopPosition(segmentStartFrame: Int64,
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
    public static func shouldReschedule(loopEnabled: Bool,
                                 eventGeneration: Int,
                                 currentGeneration: Int) -> Bool {
        loopEnabled && eventGeneration == currentGeneration
    }

    /// Playhead position when playback entered the loop mid-segment
    /// (first-pass offset): the first pass runs from
    /// `segmentStartFrame + firstPassOffsetFrames` to the segment end,
    /// later passes wrap over the full segment.
    public static func loopPosition(segmentStartFrame: Int64,
                             segmentFrameCount: Int64,
                             firstPassOffsetFrames: Int64,
                             playedFrames: Int64,
                             sampleRate: Double) -> Double {
        guard segmentFrameCount > 0, sampleRate > 0 else {
            return TimeMath.seconds(forFrames: segmentStartFrame, sampleRate: sampleRate)
        }
        let offset = Swift.min(Swift.max(0, firstPassOffsetFrames), segmentFrameCount - 1)
        let firstPassLength = segmentFrameCount - offset
        let frameInSegment: Int64
        if playedFrames < firstPassLength {
            frameInSegment = offset + playedFrames
        } else {
            frameInSegment = (playedFrames - firstPassLength) % segmentFrameCount
        }
        return TimeMath.seconds(forFrames: segmentStartFrame + frameInSegment, sampleRate: sampleRate)
    }
}

// MARK: - Note blending (v1.5.13)

/// Dynamic note blending: how long a note rings past its own
/// span into the next one, as a function of the step — which
/// already encodes tempo and speed. Adapters floor their note
/// durations at span + blend, so slow playback no longer falls
/// silent between swaras (the mechanical 1x feel); the
/// renderer's envelope release is proportional to match.
///
/// The fraction is tunable (v1.5.15): the Varisai playback
/// card carries a Blend slider while Shahzin calibrates the
/// value by ear; the shell applies the persisted value at
/// launch and the slider writes through on every change.
/// While the calibrator exists the cap is a generous 1.0 s —
/// when the value settles, the bounds get re-pinned around it.
public enum NoteBlend {
    public static var fraction = 0.30

    public static func blend(forStep step: Double) -> Double {
        fraction <= 0 ? 0 : min(1.0, fraction * step)
    }
}
