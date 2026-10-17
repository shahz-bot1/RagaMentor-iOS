import Foundation
import SwiftData
import Combine

// Single source of truth for playback state (PLAN §5): transport,
// speed, current song, playhead position (~20 Hz publish).

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published var speed: Float = 1.0 {
        didSet { engine.rate = speed }
    }
    @Published var importError: String?
    @Published var playbackError: String?

    /// Speed presets, slowest first (PLAN §2/§10).
    static let speedPresets: [Float] = [0.25, 0.5, 0.75, 1.0]

    let engine = AudioEngine()
    private var positionTimer: Timer?

    init() {
        engine.rate = speed
    }

    // MARK: - Song selection

    /// Open a song: load its file and restore the saved position (PLAN §11).
    func open(_ song: Song) {
        guard let url = song.fileURL else {
            playbackError = "The audio file for this song is missing."
            return
        }
        do {
            try engine.load(url: url)
        } catch {
            playbackError = "This song could not be loaded."
            return
        }
        currentSong = song
        position = TimeMath.clamp(song.lastPosition, min: 0, max: song.duration)
        engine.stop()
        isPlaying = false
        startPositionTimer()
    }

    func closeSong() {
        savePosition()
        engine.stop()
        isPlaying = false
        currentSong = nil
        position = 0
        stopPositionTimer()
    }

    // MARK: - Transport

    func togglePlay() {
        guard currentSong != nil else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
            savePosition()
        } else {
            if engine.loadedFile == nil, let song = currentSong { open(song) }
            if position >= (currentSong?.duration ?? 0) - 0.05 { position = 0 }
            engine.play(from: position)
            // play(from:) restarts the schedule at `position`; if the engine
            // was merely paused mid-schedule this is still correct because
            // the schedule restarts from the published position.
            isPlaying = true
        }
    }

    func play() {
        if !isPlaying { togglePlay() }
    }

    func pause() {
        if isPlaying { togglePlay() }
    }

    func seek(to seconds: Double) {
        guard let song = currentSong else { return }
        position = TimeMath.clamp(seconds, min: 0, max: song.duration)
        engine.seek(to: position)
        if !isPlaying { engine.pause() }
        savePosition()
    }

    func skip(by delta: Double) {
        seek(to: position + delta)
    }

    // MARK: - Library actions

    /// Import picked files; returns the last imported/opened song so the
    /// caller can select it. Dedupe is handled in ImportService.
    @discardableResult
    func importFiles(_ urls: [URL], context: ModelContext) -> Song? {
        var last: Song?
        for url in urls {
            do {
                last = try ImportService.importSong(from: url, context: context)
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? "Import failed."
            }
        }
        return last
    }

    /// Delete a song: stop playback if it is current, remove the stored
    /// file, delete the record (loops cascade, PLAN §6).
    func deleteSong(_ song: Song, context: ModelContext) {
        if currentSong?.id == song.id { closeSong() }
        ImportService.removeStoredFile(for: song)
        context.delete(song)
        try? context.save()
    }

    // MARK: - Position bookkeeping

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                if let p = self.engine.currentPosition() {
                    self.position = p
                    if let song = self.currentSong, p >= song.duration - 0.02 {
                        self.isPlaying = false
                        self.position = song.duration
                        self.savePosition()
                    }
                }
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// Persist the resume point (throttled by callers: pause, seek,
    /// close — PLAN §11).
    func savePosition() {
        guard let song = currentSong else { return }
        song.lastPosition = position >= song.duration ? 0 : position
    }
}
