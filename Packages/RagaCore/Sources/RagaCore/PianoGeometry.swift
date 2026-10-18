import Foundation

/// One piano key's placement on the v14 strip, in percent of the
/// container width (the web's own units).
public struct PianoKeyGeometry: Equatable, Sendable {
    public let rel: Int
    public let isBlack: Bool
    public let left: Double
    public let width: Double
}

/// The v14 piano geometry (web raga page, PIANO_VER 14), ported
/// exactly: a continuous strip over rel −1…13 in piano coordinates;
/// Sa's left edge is anchored at 0% and Sa′ (rel 12) must end at
/// exactly 100% — the neighbour keys bleed off both ends and are
/// clipped by the container. White width = 100 / (white keys in
/// rel 0…12), with a +0.62 denominator correction when Sa itself
/// is a black key; black keys are 0.62× the white width, centred
/// on the boundary between the white keys below and above them.
public enum PianoGeometry {
    private static let whitePitchClasses: Set<Int> = [0, 2, 4, 5, 7, 9, 11]

    public static func keys(saPitchClass: Int) -> [PianoKeyGeometry] {
        func pc(_ rel: Int) -> Int { ((saPitchClass + rel) % 12 + 12) % 12 }
        func isWhite(_ rel: Int) -> Bool { whitePitchClasses.contains(pc(rel)) }

        let mainWhiteCount = (0...12).filter { isWhite($0) }.count
        let ww = isWhite(0) ? 100.0 / Double(mainWhiteCount)
                            : 100.0 / (Double(mainWhiteCount) + 0.62)
        let bw = ww * 0.62

        // First pass: whites laid sequentially from rel −1.
        var whiteX: [Int: Double] = [:]
        var x = 0.0
        for rel in -1...13 where isWhite(rel) {
            whiteX[rel] = x
            x += ww
        }
        // Second pass: blacks centred on their boundary.
        var blackX: [Int: Double] = [:]
        for rel in -1...13 where !isWhite(rel) {
            var below: Int?
            var above: Int?
            for r in stride(from: rel - 1, through: -1, by: -1) where isWhite(r) {
                below = r
                break
            }
            for r in (rel + 1)...13 where isWhite(r) {
                above = r
                break
            }
            if let below, let wx = whiteX[below] {
                blackX[rel] = wx + ww - bw / 2
            } else if let above, let wx = whiteX[above] {
                blackX[rel] = wx - bw / 2
            }
        }
        // Offset so Sa's left edge sits at 0%.
        let saLeft = isWhite(0) ? (whiteX[0] ?? 0) : (blackX[0] ?? 0)
        let off = -saLeft
        var out: [PianoKeyGeometry] = []
        for rel in -1...13 {
            if isWhite(rel), let wx = whiteX[rel] {
                out.append(PianoKeyGeometry(rel: rel, isBlack: false,
                                            left: wx + off, width: ww))
            } else if let bx = blackX[rel] {
                out.append(PianoKeyGeometry(rel: rel, isBlack: true,
                                            left: bx + off, width: bw))
            }
        }
        return out
    }
}
