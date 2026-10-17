import Foundation

/// Swara sthanas and the semitone map, ported from the web suite
/// (shared by Compose, LoopLab Swaras and RagaBrowser — one identical map
/// in all three sources; R3 maps to 2 as coded on web).
public enum Swara {
    public static let semitones: [String: Int] = [
        "S": 0, "R1": 1, "R2": 2, "R3": 2, "G1": 2, "G2": 3, "G3": 4,
        "M1": 5, "M2": 6, "P": 7, "D1": 8, "D2": 9, "D3": 10,
        "N1": 9, "N2": 10, "N3": 11,
    ]

    /// The 16 sthanas in chromatic order (the picker's Chromatic list).
    public static let chromatic: [String] =
        ["S", "R1", "R2", "R3", "G1", "G2", "G3", "M1", "M2", "P", "D1", "D2", "D3", "N1", "N2", "N3"]

    public static let saNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public static func isValid(_ st: String) -> Bool { semitones[st] != nil }

    /// Absolute semitone above C4 for a sthana at an octave offset with a
    /// Sa offset applied (web: SEMI[st] + oct*12 + saOffset).
    public static func semitone(st: String, oct: Int, saOffset: Int) -> Int {
        (semitones[st] ?? 0) + oct * 12 + saOffset
    }

    /// A beat count is valid when it is a quarter multiple within
    /// 0.25...8 (web beatOK).
    public static func beatOK(_ v: Double) -> Bool {
        v >= 0.25 && v <= 8 && abs(v * 4 - (v * 4).rounded()) < 1e-9
    }

    /// "1½"-style beat formatting (web fmtBeats).
    public static func formatBeats(_ b: Double) -> String {
        let w = Int((b + 1e-9).rounded(.down))
        let f = ((b - Double(w)) * 100).rounded() / 100
        let frac: String
        switch f {
        case 0: frac = ""
        case 0.25: frac = "¼"
        case 0.5: frac = "½"
        case 0.75: frac = "¾"
        default: frac = f == 0 ? "" : String(f)
        }
        if w > 0 { return "\(w)\(frac)" }
        return frac.isEmpty ? "0" : frac
    }

    public static func durationLabel(_ b: Double) -> String {
        formatBeats(b) + (b > 1 ? " beats" : " beat")
    }
}

/// Display labels for chips (web slotLabelHTML / chipLabel): the note
/// letter carries its octave as a combining dot on the glyph itself —
/// U+0307 above for the upper octave, U+0323 below for the lower — and
/// the variant digit as a subscript.
public enum SwaraLabel {
    private static let subscripts: [Character: Character] = ["1": "₁", "2": "₂", "3": "₃"]

    public static func noteLabel(st: String, oct: Int) -> String {
        guard let first = st.first else { return st }
        var out = String(first)
        if oct > 0 { out += "\u{0307}" } else if oct < 0 { out += "\u{0323}" }
        if st.count > 1, let digit = st.last, let sub = subscripts[digit] { out.append(sub) }
        return out
    }

    public static func stackEntryLabel(_ entry: StackEntry) -> String {
        entry.isHold ? "," : noteLabel(st: entry.st ?? "", oct: entry.oct)
    }

    public static func chipLabel(_ chip: Chip) -> String {
        switch chip.kind {
        case .hold: return ","
        case .gap: return "–"
        case .note: return chip.stack.map(stackEntryLabel).joined()
        }
    }
}
