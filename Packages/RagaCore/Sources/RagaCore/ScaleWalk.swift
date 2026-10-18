import Foundation

/// Scale walking and notation for the RagaBrowser (P3): the arohana
/// up and the avarohana down as one concatenated sequence, with the
/// octave wraps the web browser plays. Semitones are relative to Sa;
/// callers add the Sa offset. Uses the shared quirky SEMI map
/// (`Swara.semitones`) so the browser sounds exactly like phrases do.
public enum ScaleWalk {
    public struct Note: Equatable, Sendable {
        public let token: String
        /// Absolute semitone relative to Sa (0 = Sa, 12 = upper Sa).
        public let semitone: Int
    }

    /// Split a scale token into its base token and octave lift:
    /// the catalog marks the upper Sa as "S'" (apostrophe), which
    /// is not itself a sthana.
    private static func split(_ token: String) -> (base: String, lift: Int) {
        if token.hasSuffix("'") || token.hasSuffix("′") {
            return (String(token.dropLast()), 1)
        }
        return (token, 0)
    }

    public static func notes(aro: [String], ava: [String]) -> [Note] {
        var out: [Note] = []
        // Arohana: each note takes the smallest octave placement
        // (honouring an explicit lift) that keeps it above the
        // previous note.
        var prevAbs = -1
        for token in aro {
            let (base, lift) = split(token)
            let pc = Swara.semitones[base] ?? 0
            var s = pc + 12 * lift
            while s <= prevAbs { s += 12 }
            out.append(Note(token: token, semitone: s))
            prevAbs = s
        }
        // Avarohana: the first token is the top note — an octave up
        // unless it carries its own lift; each next note takes the
        // highest placement below the previous note.
        var prev = Int.max
        for (index, token) in ava.enumerated() {
            let (base, lift) = split(token)
            let pc = Swara.semitones[base] ?? 0
            var s: Int
            if index == 0 {
                s = pc + 12 * max(1, lift)
            } else {
                s = pc + 12 * max(0, (prev - pc) / 12 + 1)
                while s >= prev { s -= 12 }
                while s + 12 < prev { s += 12 }
            }
            out.append(Note(token: token, semitone: s))
            prev = s
        }
        return out
    }

    public static func semitones(aro: [String], ava: [String], saOffset: Int) -> [Int] {
        notes(aro: aro, ava: ava).map { $0.semitone + saOffset }
    }

    /// The scale's pitch classes (0–11), for piano tinting and
    /// search-class matching.
    public static func pitchClasses(aro: [String], ava: [String]) -> Set<Int> {
        Set((aro + ava).map { Swara.semitones[split($0).base] ?? -1 }).subtracting([-1])
    }
}

/// Carnatic → Hindustani token mapping (web raga detail notation
/// toggle) and the Western pitch spellings (web piano label mode).
public enum ScaleNotation {
    private static let hindustaniMap: [String: String] = [
        "S": "S", "R1": "r", "R2": "R", "R3": "R",
        "G1": "g", "G2": "g", "G3": "G",
        "M1": "m", "M2": "M", "P": "P",
        "D1": "d", "D2": "D", "D3": "D",
        "N1": "n", "N2": "n", "N3": "N",
    ]

    public static func hindustani(_ token: String) -> String {
        hindustaniMap[token] ?? token
    }

    public static let westernNames =
        ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    public static func western(pitchClass: Int) -> String {
        westernNames[((pitchClass % 12) + 12) % 12]
    }
}

/// The Search tab's swara-class filter (web SWARAS12): twelve
/// collapsed classes; a class matches a raga when any scale token
/// sounds the class's pitch (enharmonic folding via the SEMI map —
/// G1 and R3 both sound the R2 class pitch, and so on).
public enum RagaSearch {
    public static let classes =
        ["S", "R1", "R2", "G2", "G3", "M1", "M2", "P", "D1", "D2", "N2", "N3"]

    public static func matches(_ raga: Raga, nameQuery: String,
                               selectedClasses: Set<String>) -> Bool {
        if !nameQuery.isEmpty,
           !raga.name.localizedCaseInsensitiveContains(nameQuery) {
            return false
        }
        if selectedClasses.isEmpty { return true }
        let scale = ScaleWalk.pitchClasses(aro: raga.aro, ava: raga.ava)
        return selectedClasses.allSatisfy {
            scale.contains(Swara.semitones[$0] ?? -2)
        }
    }
}

/// Melakarta structure: 12 chakras of 6, computed from the
/// melakarta number (web raga data).
public enum Melakarta {
    public static let chakraNames = [
        "Indu", "Netra", "Agni", "Veda", "Bana", "Rutu",
        "Rishi", "Vasu", "Brahma", "Disi", "Rudra", "Aditya",
    ]

    /// 0-based chakra index for melakarta number 1–72.
    public static func chakraIndex(forNumber number: Int) -> Int {
        (number - 1) / 6
    }

    public static func chakraName(forNumber number: Int) -> String {
        chakraNames[chakraIndex(forNumber: number)]
    }
}
