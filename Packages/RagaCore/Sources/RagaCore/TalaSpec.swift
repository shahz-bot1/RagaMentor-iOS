import Foundation

/// Tala Studio data and math (web tala/index.html): the suladi
/// sapta talas, the two fixed chapu talas, the five jatis, the
/// settings validation (including the v1 "adi" migration), tap
/// tempo and the wheel geometry. Pure logic — the web tala page
/// has no test suite, so the native suite pins all of it.
public enum TalaSpec {

    public enum Anga: String, Equatable, Sendable {
        case laghu, drutam, anudrutam
    }

    public struct TalaDef: Equatable, Sendable {
        public let id: String
        public let name: String
        public let angas: [Anga]
    }

    public struct JatiDef: Equatable, Sendable {
        public let id: String
        public let name: String
        public let value: Int
    }

    /// One anga group on the wheel: its akshara count and label.
    public struct Group: Equatable, Sendable {
        public let count: Int
        public let label: String
    }

    public static let talas: [TalaDef] = [
        TalaDef(id: "dhruva", name: "Dhruva", angas: [.laghu, .drutam, .laghu, .laghu]),
        TalaDef(id: "matya", name: "Matya", angas: [.laghu, .drutam, .laghu]),
        TalaDef(id: "rupaka", name: "Rupaka", angas: [.drutam, .laghu]),
        TalaDef(id: "jhampa", name: "Jhampa", angas: [.laghu, .anudrutam, .drutam]),
        TalaDef(id: "triputa", name: "Triputa", angas: [.laghu, .drutam, .drutam]),
        TalaDef(id: "ata", name: "Ata", angas: [.laghu, .laghu, .drutam, .drutam]),
        TalaDef(id: "eka", name: "Eka", angas: [.laghu]),
    ]

    /// Chapu talas are fixed cycles; the jati does not apply.
    public static let chapu: [(id: String, name: String, count: Int)] = [
        (id: "misraChapu", name: "Misra Chapu", count: 7),
        (id: "khandaChapu", name: "Khanda Chapu", count: 5),
    ]

    public static let jatis: [JatiDef] = [
        JatiDef(id: "tisra", name: "Tisra", value: 3),
        JatiDef(id: "chatusra", name: "Chatusra", value: 4),
        JatiDef(id: "khanda", name: "Khanda", value: 5),
        JatiDef(id: "misra", name: "Misra", value: 7),
        JatiDef(id: "sankeerna", name: "Sankeerna", value: 9),
    ]

    public static func tala(_ id: String) -> TalaDef? { talas.first { $0.id == id } }
    public static func jati(_ id: String) -> JatiDef? { jatis.first { $0.id == id } }
    public static func isChapu(_ talaId: String) -> Bool {
        chapu.contains { $0.id == talaId }
    }
    /// Adi is not a tala of its own: Triputa in Chatusra jati.
    public static func isAdi(talaId: String, jatiId: String) -> Bool {
        talaId == "triputa" && jatiId == "chatusra"
    }

    public static func groups(talaId: String, jatiId: String) -> [Group] {
        if let c = chapu.first(where: { $0.id == talaId }) {
            return [Group(count: c.count, label: "chapu")]
        }
        guard let def = tala(talaId) else { return [] }
        let jv = jati(jatiId)?.value ?? 4
        return def.angas.map { anga in
            switch anga {
            case .laghu: return Group(count: jv, label: "laghu")
            case .drutam: return Group(count: 2, label: "drutam")
            case .anudrutam: return Group(count: 1, label: "anudrutam")
            }
        }
    }

    public static func totalBeats(talaId: String, jatiId: String) -> Int {
        groups(talaId: talaId, jatiId: jatiId).reduce(0) { $0 + $1.count }
    }

    public static func comboName(talaId: String, jatiId: String) -> String {
        if let c = chapu.first(where: { $0.id == talaId }) { return c.name }
        if isAdi(talaId: talaId, jatiId: jatiId) { return "Adi" }
        return "\(jati(jatiId)?.name ?? "") \(tala(talaId)?.name ?? "")"
    }

    /// The line under the wheel: "4 + 2 + 2 · 8 aksharas / cycle",
    /// with the "Chatusra Triputa ·" prefix for Adi.
    public static func cycleLine(talaId: String, jatiId: String) -> String {
        let gs = groups(talaId: talaId, jatiId: jatiId)
        let formula = gs.map { String($0.count) }.joined(separator: " + ")
        let total = gs.reduce(0) { $0 + $1.count }
        let tail = "\(formula) · \(total) aksharas / cycle"
        if isAdi(talaId: talaId, jatiId: jatiId) {
            return "Chatusra Triputa · \(tail)"
        }
        return tail
    }

    // MARK: - Click tiers

    /// (frequency Hz, peak gain) for a subdivision slot.
    public static func click(beat: Int, sub: Int) -> (frequency: Double, gain: Double) {
        if beat == 0 && sub == 0 { return (1320, 0.55) }
        if sub == 0 { return (880, 0.45) }
        return (660, 0.22)
    }

    /// Seconds per subdivision at a tempo and nadai.
    public static func subDuration(bpm: Int, nadai: Int) -> Double {
        (60.0 / Double(bpm)) / Double(nadai)
    }

    // MARK: - Tap tempo

    /// Web tap rule: taps older than 2.5 s are dropped, at most the
    /// last 6 count, two or more are required, and the result is
    /// the rounded mean interval clamped to 30–120 bpm.
    /// `stamps` are seconds on any monotonic clock, oldest first.
    public static func tapTempo(stamps: [Double]) -> Int? {
        guard let now = stamps.last else { return nil }
        let fresh = stamps.filter { now - $0 < 2.5 }.suffix(6)
        guard fresh.count >= 2 else { return nil }
        let list = Array(fresh)
        var sum = 0.0
        for i in 1..<list.count { sum += list[i] - list[i - 1] }
        let mean = sum / Double(list.count - 1)
        guard mean > 0 else { return nil }
        let raw = Int((60.0 / mean).rounded())
        return min(120, max(30, raw))
    }

    // MARK: - Wheel geometry

    /// Dots for the 280×280 wheel: one per akshara, clockwise from
    /// the top, radius 108, anga groups separated by 0.10 rad gaps.
    public static func wheelDots(talaId: String, jatiId: String)
        -> [(x: Double, y: Double, radius: Double, isSamam: Bool)] {
        let gs = groups(talaId: talaId, jatiId: jatiId)
        let total = gs.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        let gap = 0.10
        let span = 2 * Double.pi - gap * Double(gs.count)
        let dotR = max(4.5, min(11, 300.0 / Double(total)))
        var angle = -Double.pi / 2
        var out: [(x: Double, y: Double, radius: Double, isSamam: Bool)] = []
        var index = 0
        for g in gs {
            let segment = span * (Double(g.count) / Double(total))
            for i in 0..<g.count {
                let a = angle + ((Double(i) + 0.5) / Double(g.count)) * segment
                out.append((x: 140 + 108 * cos(a), y: 140 + 108 * sin(a),
                            radius: dotR, isSamam: index == 0))
                index += 1
            }
            angle += segment + gap
        }
        return out
    }
}

/// The persisted tala settings (`tala-settings`), with the web's
/// load validation replicated: the v1 "adi" id migrates to Triputa
/// + Chatusra (a stored jati still applies afterwards), unknown
/// ids fall back, bpm must be 30–120, nadai one of 1–4.
public struct TalaSettings: Equatable, Sendable {
    public var talaId: String
    public var jatiId: String
    public var bpm: Int
    public var nadai: Int

    public init(talaId: String = "triputa", jatiId: String = "chatusra",
                bpm: Int = 60, nadai: Int = 4) {
        self.talaId = talaId
        self.jatiId = jatiId
        self.bpm = bpm
        self.nadai = nadai
    }

    /// Validate raw stored values (absent/nil = keep the default).
    public init(storedTalaId: String?, storedJatiId: String?,
                storedBPM: Int?, storedNadai: Int?) {
        self.init()
        if storedTalaId == "adi" {
            talaId = "triputa"
            jatiId = "chatusra"
        } else if let id = storedTalaId,
                  TalaSpec.tala(id) != nil || TalaSpec.isChapu(id) {
            talaId = id
        }
        if let j = storedJatiId, TalaSpec.jati(j) != nil { jatiId = j }
        if let b = storedBPM, (30...120).contains(b) { bpm = b }
        if let n = storedNadai, (1...4).contains(n) { nadai = n }
    }
}
