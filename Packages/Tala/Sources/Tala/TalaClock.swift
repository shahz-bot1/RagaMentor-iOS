import Foundation
import AVFoundation
import RagaCore
import AudioKit

/// Persistence for the tala settings under the web's own key and
/// shape (`tala-settings` JSON), validated by RagaCore's
/// TalaSettings rules.
public struct TalaSettingsStore {
    private let defaults: UserDefaults
    private let key = "tala-settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> TalaSettings {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any] else { return TalaSettings() }
        return TalaSettings(
            storedTalaId: dict["talaId"] as? String,
            storedJatiId: dict["jatiId"] as? String,
            storedBPM: (dict["bpm"] as? NSNumber)?.intValue,
            storedNadai: (dict["nadai"] as? NSNumber)?.intValue)
    }

    public func save(_ settings: TalaSettings) {
        let dict: [String: Any] = [
            "talaId": settings.talaId, "jatiId": settings.jatiId,
            "bpm": settings.bpm, "nadai": settings.nadai,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The tala clock (web engine semantics): a 25 ms lookahead
/// scheduler placing clicks 0.15 s ahead on the click engine's
/// sample timeline. Beat/subdivision state mirrors the web's
/// beatIdx/subIdx; tala and jati changes restart the cycle, a
/// nadai change only resets the subdivision index, and tempo is
/// read live at every tick.
@MainActor
public final class TalaClock: ObservableObject {
    @Published public var settings: TalaSettings {
        didSet { store.save(settings) }
    }
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentBeat = -1

    private let store: TalaSettingsStore
    private let clicks: any ClickEngine
    private var timer: Timer?
    private var nextFrame: Int64 = 0
    private var beatIdx = 0
    private var subIdx = 0
    private var taps: [Double] = []
    private var highlightTasks: [Task<Void, Never>] = []
    private var focusToken: UUID?
    private var interruptionObserver: NSObjectProtocol?

    /// Register with the cross-studio audio focus (P6). The clock
    /// keeps playing when its tab is left (the web page has no
    /// visibility handler), so the registration lives as long as
    /// the clock — another studio starting playback can stop it.
    @discardableResult
    public func attachFocus(_ focus: StudioAudioFocus) -> UUID {
        if let focusToken { return focusToken }
        let token = focus.register { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        focusToken = token
        return token
    }

    public init(store: TalaSettingsStore = TalaSettingsStore(),
                clicks: any ClickEngine = SineClickEngine()) {
        self.store = store
        self.clicks = clicks
        self.settings = store.load()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Same interruption policy as the sequence player
    /// (v1.5.17), with the subscription scoped to playback the
    /// same way (v1.5.18): a lesson tool stops and stays stopped
    /// when another app takes the audio session; the click
    /// engine heals itself, so the next manual Start sounds.
    private func subscribeToInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began
                else { return }
                Task { @MainActor in self?.stop() }
            }
    }

    private func unsubscribeFromInterruptions() {
        guard let token = interruptionObserver else { return }
        NotificationCenter.default.removeObserver(token)
        interruptionObserver = nil
    }

    private var totalBeats: Int {
        TalaSpec.totalBeats(talaId: settings.talaId, jatiId: settings.jatiId)
    }

    // MARK: - Transport

    public func toggle() {
        isPlaying ? stop() : start()
    }

    public func start() {
        guard !isPlaying else { return }
        subscribeToInterruptions()
        clicks.prepare()
        beatIdx = 0
        subIdx = 0
        nextFrame = clicks.currentFrame + Int64(0.08 * clicks.sampleRate)
        isPlaying = true
        let scheduler = Timer(timeInterval: 0.025, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common mode (v1.5.22): a default-mode timer stalls
        // while the user scrolls (run-loop tracking mode), and
        // stalled ticks would leave gaps in the click lookahead.
        RunLoop.main.add(scheduler, forMode: .common)
        timer = scheduler
    }

    public func stop() {
        unsubscribeFromInterruptions()
        timer?.invalidate()
        timer = nil
        clicks.clear()
        highlightTasks.forEach { $0.cancel() }
        highlightTasks = []
        isPlaying = false
        currentBeat = -1
    }

    /// Tala/jati change while playing: back to samam, first click
    /// +0.08 s out. Clicks already inside the lookahead window
    /// still sound, as on the web.
    private func restartCycle() {
        guard isPlaying else { return }
        beatIdx = 0
        subIdx = 0
        nextFrame = clicks.currentFrame + Int64(0.08 * clicks.sampleRate)
    }

    private func tick() {
        guard isPlaying else { return }
        let sr = clicks.sampleRate
        let subDur = TalaSpec.subDuration(bpm: settings.bpm, nadai: settings.nadai)
        let horizon = clicks.currentFrame + Int64(0.15 * sr)
        while nextFrame < horizon {
            let click = TalaSpec.click(beat: beatIdx, sub: subIdx)
            clicks.scheduleClick(atFrame: nextFrame,
                                 frequency: click.frequency,
                                 gain: Float(click.gain))
            if subIdx == 0 {
                scheduleHighlight(beat: beatIdx, atFrame: nextFrame)
            }
            nextFrame += Int64(subDur * sr)
            subIdx += 1
            if subIdx >= settings.nadai {
                subIdx = 0
                beatIdx = (beatIdx + 1) % max(1, totalBeats)
            }
        }
    }

    private func scheduleHighlight(beat: Int, atFrame frame: Int64) {
        let delay = max(0, Double(frame - clicks.currentFrame) / clicks.sampleRate)
        highlightTasks.append(Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if isPlaying { currentBeat = beat }
        })
    }

    // MARK: - Settings edits (each persists, via didSet)

    public func setTala(_ id: String) {
        settings.talaId = id
        restartCycle()
    }

    public func setJati(_ id: String) {
        settings.jatiId = id
        restartCycle()
    }

    /// A nadai change mid-play resets only the subdivision index.
    public func setNadai(_ n: Int) {
        settings.nadai = n
        subIdx = 0
    }

    public func setBPM(_ bpm: Int) {
        settings.bpm = min(120, max(30, bpm))
    }

    /// One tap-tempo tap; applies the web rule via TalaSpec.
    public func tap() {
        taps.append(ProcessInfo.processInfo.systemUptime)
        if let bpm = TalaSpec.tapTempo(stamps: taps) {
            setBPM(bpm)
        }
    }
}
