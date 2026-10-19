import Foundation
import RagaCore

/// Varisai token and playback math, ported from the web player.
/// Token encoding (from the lesson data): a sthana ("R1"), the
/// upper octave with a trailing apostrophe ("R1'"), the lower
/// octave with a leading comma (",D1"), and "," alone is a
/// dheergam hold that extends the preceding note by one step.
public enum VarisaiToken {
    public enum Kind: Equatable {
        case note(sthana: String, octave: Int)
        case hold
    }

    public static func parse(_ token: String) -> Kind {
        if token == "," { return .hold }
        if token.hasPrefix(",") {
            return .note(sthana: String(token.dropFirst()), octave: -1)
        }
        if token.hasSuffix("'") {
            return .note(sthana: String(token.dropLast()), octave: 1)
        }
        return .note(sthana: token, octave: 0)
    }

    /// A rest/hold token (the web's isRest): a dheergam comma or a
    /// dash.
    public static func isRest(_ token: String) -> Bool {
        token == "," || token == "-"
    }

    /// Absolute semitone (Sa offset applied); nil for a hold.
    public static func semitone(_ token: String, saOffset: Int) -> Int? {
        guard case .note(let sthana, let octave) = parse(token) else { return nil }
        return (Swara.semitones[sthana] ?? 0) + 12 * octave + saOffset
    }

    private static let subscripts: [Character: String] = [
        "1": "₁", "2": "₂", "3": "₃",
    ]

    /// Display label. Simple labels strip the sthana digit; full
    /// labels show it as a subscript. The lower octave carries the
    /// combining dot below on the letter; the upper octave an
    /// apostrophe. Holds show the dheergam comma.
    public static func label(_ token: String, full: Bool) -> String {
        guard case .note(let sthana, let octave) = parse(token) else { return "," }
        let letter = String(sthana.prefix(1))
        let digit = sthana.last.flatMap { subscripts[$0] } ?? ""
        var out = letter
        if octave < 0 { out += "\u{0323}" }
        if full { out += digit }
        if octave > 0 { out += "'" }
        return out
    }
}

/// One scheduled note: which step it starts on and how many steps
/// it spans (dheergam holds add steps to their note).
public struct VarisaiEvent: Equatable, Sendable {
    public let semitone: Int
    public let startStep: Int
    public var slots: Int

    public init(semitone: Int, startStep: Int, slots: Int) {
        self.semitone = semitone
        self.startStep = startStep
        self.slots = slots
    }
}

public enum VarisaiPlayback {
    /// Build the note events for a pattern: one step per token,
    /// each hold token adding one slot to the nearest preceding
    /// note (a leading hold with no note before it sounds nothing).
    public static func events(notes: [String], saOffset: Int) -> [VarisaiEvent] {
        var out: [VarisaiEvent] = []
        for (index, token) in notes.enumerated() {
            switch VarisaiToken.parse(token) {
            case .hold:
                if !out.isEmpty { out[out.count - 1].slots += 1 }
            case .note:
                if let semitone = VarisaiToken.semitone(token, saOffset: saOffset) {
                    out.append(VarisaiEvent(semitone: semitone,
                                            startStep: index, slots: 1))
                }
            }
        }
        return out
    }

    /// The legato overlap factor for a speed (web player): how far
    /// each note rings past its slot(s).
    public static func overlap(speed: Int, step: Double) -> Double {
        switch speed {
        case 8: return max(2.0, 0.25 / step)
        case 4: return 1.8
        default: return 1 + min(1.5, (0.075 * Double(speed)) / step)
        }
    }

    /// Sounding duration of one event. The final event follows the
    /// web's closing rule: at least one overlapped step.
    public static func duration(of event: VarisaiEvent, isLast: Bool,
                                step: Double, speed: Int) -> Double {
        let factor = overlap(speed: speed, step: step)
        let base = step * Double(event.slots) * factor
        // Dynamic blending (v1.5.13): every event also rings at
        // least a blend past its own span, so slow speeds no
        // longer fall silent between swaras. A floor only — the
        // legato factors above it (4x/8x) are unchanged.
        let blended = step * Double(event.slots) + NoteBlend.blend(forStep: step)
        let dur = max(base, blended)
        return isLast ? max(dur * 0.96, step * factor) : dur
    }

    /// Beat count of an alankaram tala string: I<n> = n beats
    /// (laghu), 0 = 2 (drutam), U = 1 (anudrutam).
    /// Per-anga beat counts (web talaDisplay): I<n> = n,
    /// 0 (drutam) = 2, U (anudrutam) = 1.
    public static func angaBeats(_ tala: String) -> [Int] {
        tala.split(separator: " ").map { anga in
            if anga.hasPrefix("I"), let n = Int(anga.dropFirst()) { return n }
            if anga == "0" { return 2 }
            if anga == "U" { return 1 }
            return 0
        }
    }

    public static func talaBeats(_ tala: String) -> Int {
        tala.split(separator: " ").reduce(0) { sum, part in
            if part == "0" { return sum + 2 }
            if part == "U" { return sum + 1 }
            if part.hasPrefix("I"), let n = Int(part.dropFirst()) { return sum + n }
            return sum
        }
    }
}


/// Laya string parsing (web layaDisplay): parts split on
/// " and "; each part's groups split on "-" (a logical separator,
/// never a rest); parenthesised count hints are stripped; a part
/// without "-" is one group with its spaces removed.
public enum LayaParts {
    public static func parse(_ laya: String) -> [[String]] {
        laya.components(separatedBy: " and ").map { part in
            var text = part
            while let open = text.firstIndex(of: "("),
                  let close = text[open...].firstIndex(of: ")") {
                text.removeSubrange(open...close)
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.contains("-") {
                return [text.replacingOccurrences(of: " ", with: "")]
            }
            return text.split(separator: " ").flatMap {
                $0.split(separator: "-").map(String.init)
            }.filter { !$0.isEmpty }
        }
    }
}
