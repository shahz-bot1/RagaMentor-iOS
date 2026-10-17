import Foundation
import SwiftData
import AVFoundation
import CryptoKit

// Import pipeline per PLAN §8: pick file -> SHA-256 (streamed) ->
// dedupe by hash -> copy to Application Support/Audio/<hash>.<ext> ->
// metadata via AVAudioFile -> Song record.

enum ImportError: LocalizedError {
    case unreadableFile
    case unsupportedOrCorrupt
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "That file could not be read."
        case .unsupportedOrCorrupt: return "That file is not a supported audio file, or it is corrupt."
        case .storageFailed: return "The file could not be stored on this device."
        }
    }
}

enum ImportService {

    /// Application Support/Audio directory, created on demand.
    static func audioDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            throw ImportError.storageFailed
        }
        let dir = base.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stored-file name for a content hash: "<hash>.<ext>" (PLAN §8.4).
    static func storedFileName(hash: String, sourceExtension: String) -> String {
        let ext = sourceExtension.lowercased()
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    /// Relative path stored on the Song record.
    static func relativePath(hash: String, sourceExtension: String) -> String {
        "Audio/\(storedFileName(hash: hash, sourceExtension: sourceExtension))"
    }

    /// Streamed SHA-256 of a file (1 MB chunks, so large files stay cheap).
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ImportError.unreadableFile
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Import one picked file. If a Song with the same content hash already
    /// exists it is returned untouched (loops intact — PLAN §8.3) and the
    /// picked file is discarded.
    @MainActor
    static func importSong(from pickedURL: URL, context: ModelContext) throws -> Song {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let hash = try sha256Hex(ofFileAt: pickedURL)

        let descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.contentHash == hash })
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let ext = pickedURL.pathExtension
        let dir = try audioDirectory()
        let dest = dir.appendingPathComponent(storedFileName(hash: hash, sourceExtension: ext))
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        } catch {
            throw ImportError.storageFailed
        }

        let duration: Double
        let sampleRate: Double
        do {
            let file = try AVAudioFile(forReading: dest)
            sampleRate = file.fileFormat.sampleRate
            duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.unsupportedOrCorrupt
        }
        guard duration > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw ImportError.unsupportedOrCorrupt
        }

        let title = pickedURL.deletingPathExtension().lastPathComponent
        let song = Song(title: title.isEmpty ? "Untitled" : title,
                        contentHash: hash,
                        fileRelativePath: relativePath(hash: hash, sourceExtension: ext),
                        duration: duration,
                        sampleRate: sampleRate)
        context.insert(song)
        try context.save()
        return song
    }

    /// Delete a song's stored audio file (record deletion happens in the
    /// controller so playback can be stopped first). PLAN §6: deleting a
    /// song removes the audio file; peaks sidecar arrives with M5.
    static func removeStoredFile(for song: Song) {
        guard let url = song.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
