import SwiftUI

/// Lifecycle-scoped playback subscription (v1.5.29 — Shahzin's
/// scoping rule: subscribe only when required).
///
/// A view may listen to the shared player's stream only while
/// BOTH hold: its screen is visible, and a pass for its own
/// context is playing. Scoping a READ (isPlaying(contextKey:))
/// never did this — it filtered the value a view rendered, not
/// the rebuild: every publish on the shared player re-ran every
/// observer's body, in every studio, visible or not.
///
/// The gate is the only observer. Its body is one scoped check;
/// it hands the content closure the scoped state — (live,
/// currentIndex). While not live, the content renders from the
/// plain (-1) index and, its inputs unchanged, SwiftUI diffing
/// leaves it untouched no matter what plays elsewhere. When its
/// own pass starts, the gate's next publish flips it live and
/// the highlights flow.
///
/// Visibility is the HOST's call, not the gate's: hosts fold
/// their appear state AND the scene phase into the one flag
/// (a backgrounded app's screens are not visible). The gate
/// owns only the playback condition — splitting it this way
/// also keeps the gate testable in a bare hosting window,
/// where no scene is active.
public struct PlaybackGate<Content: View>: View {
    @ObservedObject private var player: SequencePlayer
    private let contextKey: String
    private let visible: Bool
    private let content: (Bool, Int) -> Content

    public init(player: SequencePlayer, contextKey: String,
                visible: Bool = true,
                @ViewBuilder content: @escaping (Bool, Int) -> Content) {
        self.player = player
        self.contextKey = contextKey
        self.visible = visible
        self.content = content
    }

    /// Live = host says the screen is visible (foreground and
    /// on screen), and a pass for this context is playing.
    private var live: Bool {
        visible && player.isPlaying(contextKey: contextKey)
    }

    public var body: some View {
        content(live, live ? player.currentIndex : -1)
    }
}
