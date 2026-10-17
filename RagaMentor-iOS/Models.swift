import Foundation
import SwiftData

// Data model per PLAN.md §6. Persistence: SwiftData, fully on-device.

@Model
final class Song {
    @Attribute(.unique) var id: UUID
    var title: String
    /// SHA-256 of the file bytes; the dedupe key (PLAN §3 decision 4).
    var contentHash: String
    /// Path relative to Application Support, e.g. "Audio/<hash>.mp3".
    var fileRelativePath: String
    var duration: Double
    var sampleRate: Double
    var dateAdded: Date
    var lastPosition: Double
    var lastLoopID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \LoopRegion.song) var loops: [LoopRegion]
    @Relationship(deleteRule: .cascade, inverse: \LoopGroup.song) var groups: [LoopGroup]

    init(id: UUID = UUID(),
         title: String,
         contentHash: String,
         fileRelativePath: String,
         duration: Double,
         sampleRate: Double,
         dateAdded: Date = Date(),
         lastPosition: Double = 0,
         lastLoopID: UUID? = nil,
         loops: [LoopRegion] = [],
         groups: [LoopGroup] = []) {
        self.id = id
        self.title = title
        self.contentHash = contentHash
        self.fileRelativePath = fileRelativePath
        self.duration = duration
        self.sampleRate = sampleRate
        self.dateAdded = dateAdded
        self.lastPosition = lastPosition
        self.lastLoopID = lastLoopID
        self.loops = loops
        self.groups = groups
    }

    /// Absolute URL of the stored audio file.
    var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(fileRelativePath)
    }
}

@Model
final class LoopRegion {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Free text: key, vocal/swara cues (PLAN §2).
    var note: String
    var start: Double
    var end: Double
    var sortOrder: Int
    var createdAt: Date
    var song: Song?

    init(id: UUID = UUID(),
         name: String,
         note: String = "",
         start: Double,
         end: Double,
         sortOrder: Int = 0,
         createdAt: Date = Date(),
         song: Song? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.start = start
        self.end = end
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.song = song
    }
}

@Model
final class LoopGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    /// LoopRegion OR LoopGroup ids, kept sorted by start time.
    /// Range is DERIVED bottom-up (GroupLogic), never stored (PLAN §6).
    var memberIDs: [UUID]
    var song: Song?

    init(id: UUID = UUID(),
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
