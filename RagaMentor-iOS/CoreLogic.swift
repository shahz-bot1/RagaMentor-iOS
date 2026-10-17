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

// MARK: - Group membership operations (M3, PLAN §3/§6)

/// A group's membership as plain data, for pure transformations.
struct GroupData: Equatable {
    var id: UUID
    var memberIDs: [UUID]
}

enum GroupOps {
    /// group id -> parent group id, from all groups' member lists.
    static func parentMap(groups: [GroupData]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for g in groups {
            for member in g.memberIDs { map[member] = g.id }
        }
        return map
    }

    /// All loop ids under a group, directly or through sub-groups.
    static func descendantLoopIDs(of groupID: UUID,
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
    static func emptyGroupIDs(groups: [GroupData], loopIDs: Set<UUID>) -> Set<UUID> {
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
    static func sortedMemberIDs(_ memberIDs: [UUID],
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
    static func deletingGroup(_ groupID: UUID, from groups: [GroupData]) -> [GroupData] {
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
    static func settingMembers(of groupID: UUID,
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

// MARK: - Loops backup format v1 (M4, PLAN §11)

/// File-local backup of one song's loops and groups. Ids inside the file
/// are serial integers, never DB ids; references between entries are by
/// serial + name. Import replaces all loops/groups and mints fresh ids.
struct LoopsBackupFile: Codable, Equatable {
    struct LoopEntry: Codable, Equatable {
        var serial: Int
        var name: String
        var note: String
        var start: Double
        var end: Double
    }
    struct GroupEntry: Codable, Equatable {
        var serial: Int
        var name: String
        var colorHex: String
        var memberSerials: [Int]
    }
    var version: Int = 1
    var songTitle: String
    var duration: Double
    var loops: [LoopEntry]
    var groups: [GroupEntry]
}

enum LoopsBackup {
    enum BackupError: Error { case unsupportedVersion, malformed }

    /// Build the backup file from model-shaped data. Serials are assigned
    /// loops first (in the given order), then groups.
    static func make(songTitle: String,
                     duration: Double,
                     loops: [LoopRegionSnapshot],
                     groups: [LoopGroupSnapshot]) -> LoopsBackupFile {
        var serialByID: [UUID: Int] = [:]
        var next = 1
        var loopEntries: [LoopsBackupFile.LoopEntry] = []
        for loop in loops {
            serialByID[loop.id] = next
            loopEntries.append(.init(serial: next, name: loop.name, note: loop.note,
                                     start: loop.start, end: loop.end))
            next += 1
        }
        var groupEntries: [LoopsBackupFile.GroupEntry] = []
        for group in groups {
            serialByID[group.id] = next
            groupEntries.append(.init(serial: next, name: group.name, colorHex: group.colorHex,
                                      memberSerials: []))
            next += 1
        }
        for (i, group) in groups.enumerated() {
            groupEntries[i].memberSerials = group.memberIDs.compactMap { serialByID[$0] }
        }
        return LoopsBackupFile(songTitle: songTitle, duration: duration,
                               loops: loopEntries, groups: groupEntries)
    }

    /// A loop/group as the backup layer sees it (storage-agnostic).
    struct LoopRegionSnapshot {
        var id: UUID; var name: String; var note: String; var start: Double; var end: Double
    }
    struct LoopGroupSnapshot {
        var id: UUID; var name: String; var colorHex: String; var memberIDs: [UUID]
    }

    /// Planned import result with fresh DB ids minted.
    struct PlannedLoop { var id: UUID; var name: String; var note: String; var start: Double; var end: Double }
    struct PlannedGroup { var id: UUID; var name: String; var colorHex: String; var memberIDs: [UUID] }

    /// Validate a backup file against the target song's duration and plan
    /// the replacement: ranges re-normalised, unknown serials dropped,
    /// memberships that would break the 2-level cap dropped (a sub-group
    /// may not itself hold groups).
    static func planImport(file: LoopsBackupFile, duration: Double) throws
        -> (loops: [PlannedLoop], groups: [PlannedGroup]) {
        guard file.version == 1 else { throw BackupError.unsupportedVersion }

        var idBySerial: [Int: UUID] = [:]
        var plannedLoops: [PlannedLoop] = []
        for entry in file.loops {
            guard let range = LoopRules.normalize(start: entry.start, end: entry.end, duration: duration)
            else { continue }
            let id = UUID()
            idBySerial[entry.serial] = id
            plannedLoops.append(PlannedLoop(id: id, name: entry.name, note: entry.note,
                                            start: range.start, end: range.end))
        }
        plannedLoops.sort { ($0.start, $0.end) < ($1.start, $1.end) }

        // Groups whose members include another group are "holders"; a
        // holder may not itself be a member of any group (depth cap).
        let groupSerials = Set(file.groups.map(\.serial))
        let holderSerials = Set(file.groups.filter { g in
            g.memberSerials.contains { groupSerials.contains($0) }
        }.map(\.serial))

        var plannedGroups: [PlannedGroup] = []
        for entry in file.groups {
            let id = UUID()
            idBySerial[entry.serial] = id
            plannedGroups.append(PlannedGroup(id: id, name: entry.name,
                                              colorHex: entry.colorHex, memberIDs: []))
        }
        for (i, entry) in file.groups.enumerated() {
            var members: [UUID] = []
            for serial in entry.memberSerials {
                guard let memberID = idBySerial[serial] else { continue }
                if groupSerials.contains(serial) && holderSerials.contains(serial) {
                    continue // would nest a holder inside a group: cap breach
                }
                members.append(memberID)
            }
            plannedGroups[i].memberIDs = members
        }
        // Drop groups left with no descendant loops (they vanish, §6),
        // and strip references to them from surviving groups.
        let loopIDs = Set(plannedLoops.map(\.id))
        let groupData = plannedGroups.map { GroupData(id: $0.id, memberIDs: $0.memberIDs) }
        let empty = GroupOps.emptyGroupIDs(groups: groupData, loopIDs: loopIDs)
        plannedGroups.removeAll { empty.contains($0.id) }
        if !empty.isEmpty {
            for i in plannedGroups.indices {
                plannedGroups[i].memberIDs.removeAll { empty.contains($0) }
            }
        }
        return (plannedLoops, plannedGroups)
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

    /// Playhead position when playback entered the loop mid-segment
    /// (first-pass offset): the first pass runs from
    /// `segmentStartFrame + firstPassOffsetFrames` to the segment end,
    /// later passes wrap over the full segment.
    static func loopPosition(segmentStartFrame: Int64,
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
