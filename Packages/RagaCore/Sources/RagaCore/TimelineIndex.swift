import Foundation

/// Pure timeline math for the shared SequencePlayer (design:
/// SequencePlayer Detailed Design §6.3). Index-from-elapsed is
/// computed here, once, and unit-tested — no player derives a
/// highlight from sleeping tasks any more.
public enum TimelineIndex {

    /// The highlight index at `elapsed` seconds into a pass, given
    /// each highlight's start offset inside the pass. Binary search;
    /// -1 before the first start; clamped to `count - 1` after the
    /// last. `count` is the number of highlights (the starts array
    /// normally has the same length).
    public static func index(at elapsed: Double, starts: [Double], count: Int) -> Int {
        guard count > 0, !starts.isEmpty, elapsed >= starts[0] else { return -1 }
        var lo = 0
        var hi = min(starts.count, count) - 1
        // Invariant: starts[lo] <= elapsed.
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= elapsed { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Which pass an elapsed time falls in, and the offset inside
    /// that pass — pure origin arithmetic (pass = elapsed ÷
    /// duration), so long sessions cannot accumulate drift.
    public static func pass(elapsed: Double, duration: Double) -> (pass: Int, offset: Double) {
        guard duration > 0, elapsed > 0 else { return (0, max(0, elapsed)) }
        let p = Int(elapsed / duration)
        return (p, elapsed - Double(p) * duration)
    }
}
