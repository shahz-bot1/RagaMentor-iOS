import Foundation
import SwiftData

// Data model per PLAN.md §6. PersistenceKit (PARITY-PLAN §3.1):
// SwiftData, fully on-device.

@Model
public final class Song {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// SHA-256 of the file bytes; the dedupe key (PLAN §3 decision 4).
    public var contentHash: String
    /// Path relative to Application Support, e.g. "Audio/<hash>.mp3".
    public var fileRelativePath: String
    public var duration: Double
    public var sampleRate: Double
    public var dateAdded: Date
    /// When the song's CONTENT last changed — a loop, group,
    /// phrase, note, title or raga edit (v1.5.39). The library
    /// sorts by it, newest first. Playback bookkeeping
    /// (lastPosition, lastLoopID) never moves it. Rows from
    /// before v1.5.39 migrate to the distant past and keep
    /// their dateAdded order (the sort's tiebreak) until their
    /// first edit.
    public var updatedAt: Date = Date.distantPast
    public var lastPosition: Double
    public var lastLoopID: UUID?
    /// Per-song raga memory: the raga last used for this song's swara
    /// phrases (web song.swRagaId); new phrases preselect it.
    public var swRagaId: String?
    @Relationship(deleteRule: .cascade, inverse: \LoopRegion.song) public var loops: [LoopRegion]
    @Relationship(deleteRule: .cascade, inverse: \LoopGroup.song) public var groups: [LoopGroup]

    public init(id: UUID = UUID(),
         title: String,
         contentHash: String,
         fileRelativePath: String,
         duration: Double,
         sampleRate: Double,
         dateAdded: Date = Date(),
         updatedAt: Date? = nil,
         lastPosition: Double = 0,
         lastLoopID: UUID? = nil,
         swRagaId: String? = nil,
         loops: [LoopRegion] = [],
         groups: [LoopGroup] = []) {
        self.id = id
        self.title = title
        self.contentHash = contentHash
        self.fileRelativePath = fileRelativePath
        self.duration = duration
        self.sampleRate = sampleRate
        self.dateAdded = dateAdded
        self.updatedAt = updatedAt ?? dateAdded
        self.lastPosition = lastPosition
        self.lastLoopID = lastLoopID
        self.swRagaId = swRagaId
        self.loops = loops
        self.groups = groups
    }

    /// Absolute URL of the stored audio file.
    public var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(fileRelativePath)
    }
}

@Model
public final class LoopRegion {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Free text: key, vocal/swara cues (PLAN §2).
    public var note: String
    public var start: Double
    public var end: Double
    public var sortOrder: Int
    public var createdAt: Date
    /// The loop's swara phrase as canonical Phrase JSON (nil = no
    /// phrase). The phrase lives on the loop, never in a shared store.
    public var swarasJSON: String?
    public var song: Song?

    public init(id: UUID = UUID(),
         name: String,
         note: String = "",
         start: Double,
         end: Double,
         sortOrder: Int = 0,
         createdAt: Date = Date(),
         swarasJSON: String? = nil,
         song: Song? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.start = start
        self.end = end
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.swarasJSON = swarasJSON
        self.song = song
    }
}

@Model
public final class LoopGroup {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var colorHex: String
    /// LoopRegion OR LoopGroup ids, kept sorted by start time.
    /// Range is DERIVED bottom-up (GroupLogic), never stored (PLAN §6).
    public var memberIDs: [UUID]
    public var song: Song?

    public init(id: UUID = UUID(),
         name: String,
         colorHex: String = "#5b9dff",
         memberIDs: [UUID] = [],
         song: Song? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.memberIDs = memberIDs
        self.song = song
    }
}
