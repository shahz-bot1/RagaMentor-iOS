import Foundation

/// Nearest-sample mapping for the harmonium set — a port of the web
/// swSampleFor. Available samples are C4...C5 minus F#4; anything else
/// uses the nearest sample with a playback-rate shift.
public enum SampleMap {
    public static let availableSemitones = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12]
    public static let fileNames = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]

    public static func sample(forSemitone semi: Int) -> (fileName: String, rate: Double) {
        let baseSemi = ((semi % 12) + 12) % 12
        let oct = 4 + floorDiv(semi, 12)
        var file = fileNames[baseSemi] + String(oct) + ".mp3"
        if availableSemitones.contains(semi) && file != "Fs4.mp3" {
            return (file, 1)
        }
        var best = availableSemitones[0]
        var bestDist = Int.max
        for a in availableSemitones {
            let d = abs(a - semi)
            if d < bestDist { bestDist = d; best = a } // first wins ties (web)
        }
        file = fileNames[best % 12] + String(4 + best / 12) + ".mp3"
        return (file, pow(2, Double(semi - best) / 12))
    }

    /// The bundled file for an available semitone (0 → C4 ... 12 → C5).
    public static func fileName(forAvailableSemitone semi: Int) -> String {
        fileNames[semi % 12] + String(4 + semi / 12) + ".mp3"
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }
}
