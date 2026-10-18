import Foundation

/// Cross-studio audio focus (P6 hardening): every studio that can
/// make sound registers a stop closure while it is on screen, and
/// whoever starts playback stops the others first — so the song, a
/// phrase, a raga scale, a varisai pattern and the tala clicks
/// never overlap. AppShell owns the one instance and shares it
/// through the view environment.
public final class StudioAudioFocus: ObservableObject {
    private var stops: [UUID: () -> Void] = [:]

    public init() {}

    /// Register a stop closure; returns the token that identifies
    /// this registration (pass it back to `stopAll(except:)` and
    /// `unregister`).
    @discardableResult
    public func register(_ stop: @escaping () -> Void) -> UUID {
        let token = UUID()
        stops[token] = stop
        return token
    }

    public func unregister(_ token: UUID) {
        stops[token] = nil
    }

    /// Stop everything registered, optionally sparing one token
    /// (the studio that is starting playback).
    public func stopAll(except token: UUID? = nil) {
        for (id, stop) in stops where id != token {
            stop()
        }
    }

    /// How many studios are registered (diagnostics/tests).
    public var registeredCount: Int { stops.count }
}
