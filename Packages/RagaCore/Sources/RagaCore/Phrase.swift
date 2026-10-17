import Foundation

/// One entry inside a note chip's stack: a sthana at an octave offset, or
/// a hold marker that extends the preceding unit inside the stack.
/// JSON shape (web): {"st":"R2","oct":0} or {"hold":true}.
public struct StackEntry: Equatable, Sendable {
    public var st: String?
    public var oct: Int
    public var isHold: Bool

    public init(st: String, oct: Int) { self.st = st; self.oct = oct; self.isHold = false }
    public init(hold: Void) { self.st = nil; self.oct = 0; self.isHold = true }
    public static let hold = StackEntry(hold: ())
}

extension StackEntry: Codable {
    private enum CodingKeys: String, CodingKey { case st, oct, hold }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decode(Bool.self, forKey: .hold)) == true {
            self.st = nil
            self.oct = 0
            self.isHold = true
        } else {
            self.st = try c.decode(String.self, forKey: .st)
            self.oct = try c.decodeIfPresent(Int.self, forKey: .oct) ?? 0
            self.isHold = false
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if isHold {
            try c.encode(true, forKey: .hold)
        } else {
            try c.encode(st ?? "", forKey: .st)
            try c.encode(oct, forKey: .oct)
        }
    }
}

public enum ChipKind: String, Equatable, Sendable { case note, hold, gap }

/// One chip of a phrase. JSON shape (web): {"k":"note","stack":[…],
/// "beats":1} / {"k":"hold","beats":1} / {"k":"gap","beats":1}.
public struct Chip: Equatable, Sendable {
    public var kind: ChipKind
    public var stack: [StackEntry]
    public var beats: Double

    public init(kind: ChipKind, stack: [StackEntry] = [], beats: Double) {
        self.kind = kind; self.stack = stack; self.beats = beats
    }
    public static func note(_ stack: [StackEntry], beats: Double) -> Chip {
        Chip(kind: .note, stack: stack, beats: beats)
    }
    public static func hold(beats: Double) -> Chip { Chip(kind: .hold, beats: beats) }
    public static func gap(beats: Double) -> Chip { Chip(kind: .gap, beats: beats) }
}

extension Chip: Codable {
    private enum CodingKeys: String, CodingKey { case k, stack, beats }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = try c.decode(String.self, forKey: .k)
        self.kind = ChipKind(rawValue: k) ?? .note
        self.stack = (try? c.decode([StackEntry].self, forKey: .stack)) ?? []
        self.beats = try c.decode(Double.self, forKey: .beats)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .k)
        if kind == .note { try c.encode(stack, forKey: .stack) }
        try c.encode(beats, forKey: .beats)
    }
}

/// A swara phrase — the shape shared by LoopLab loop phrases and (from
/// P2) Compose compositions. JSON keys match the web format exactly.
public struct Phrase: Equatable, Sendable {
    public var ragaId: String?
    public var saOffset: Int
    public var tempo: Int
    public var loop: Bool
    public var chips: [Chip]

    public init(ragaId: String?, saOffset: Int, tempo: Int, loop: Bool, chips: [Chip]) {
        self.ragaId = ragaId; self.saOffset = saOffset; self.tempo = tempo
        self.loop = loop; self.chips = chips
    }

    public var totalBeats: Double { chips.reduce(0) { $0 + $1.beats } }
    public var hasNotes: Bool { chips.contains { $0.kind == .note } }
}

extension Phrase: Codable {
    private enum CodingKeys: String, CodingKey { case ragaId, saOffset, tempo, loop, chips }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ragaId = try c.decodeIfPresent(String.self, forKey: .ragaId) ?? nil
        self.saOffset = try c.decode(Int.self, forKey: .saOffset)
        self.tempo = try c.decode(Int.self, forKey: .tempo)
        self.loop = try c.decode(Bool.self, forKey: .loop)
        self.chips = try c.decode([Chip].self, forKey: .chips)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ragaId, forKey: .ragaId) // null when nil, as on web
        try c.encode(saOffset, forKey: .saOffset)
        try c.encode(tempo, forKey: .tempo)
        try c.encode(loop, forKey: .loop)
        try c.encode(chips, forKey: .chips)
    }

    /// Canonical JSON data for storage/export (keys sorted for stability).
    public func jsonData() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(self)
    }
    public static func fromJSON(_ data: Data) -> Phrase? {
        try? JSONDecoder().decode(Phrase.self, from: data)
    }
    public static func fromJSONString(_ string: String) -> Phrase? {
        fromJSON(Data(string.utf8))
    }
    public func jsonString() -> String? {
        jsonData().flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The phrase sanitizer — a faithful port of the web sanitizePhrase.
/// Accepts a bare phrase object or a {"composition": …} envelope. Any
/// malformed chip or stack entry rejects the WHOLE phrase; fixable field
/// values are coerced (beats snap to 1 when invalid, tempo clamps to
/// 30...120 with default 60, unknown raga becomes nil = Chromatic).
public enum PhraseSanitizer {
    public static func sanitize(data: Data, isKnownRaga: (String) -> Bool) -> Phrase? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return sanitize(jsonObject: obj, isKnownRaga: isKnownRaga)
    }

    public static func sanitize(phrase: Phrase, isKnownRaga: (String) -> Bool) -> Phrase? {
        guard let data = phrase.jsonData() else { return nil }
        return sanitize(data: data, isKnownRaga: isKnownRaga)
    }

    public static func sanitize(jsonObject: Any, isKnownRaga: (String) -> Bool) -> Phrase? {
        var root = jsonObject as? [String: Any]
        if let envelope = root?["composition"] as? [String: Any] { root = envelope }
        guard let c = root, let rawChips = c["chips"] as? [Any] else { return nil }

        var chips: [Chip] = []
        for rawChip in rawChips {
            guard let ch = rawChip as? [String: Any] else { return nil }
            let beatsRaw = jsNumber(ch["beats"])
            let beats = beatsRaw.map { Swara.beatOK($0) ? ($0 * 4).rounded() / 4 : 1 } ?? 1
            let k = ch["k"] as? String
            if k == "hold" { chips.append(.hold(beats: beats)); continue }
            if k == "gap" { chips.append(.gap(beats: beats)); continue }
            guard k == "note", let rawStack = ch["stack"] as? [Any], !rawStack.isEmpty
            else { return nil }
            var stack: [StackEntry] = []
            for rawEntry in rawStack {
                guard let n = rawEntry as? [String: Any] else { return nil }
                if (n["hold"] as? Bool) == true { stack.append(.hold); continue }
                guard let st = n["st"] as? String, Swara.isValid(st) else { return nil }
                let octRaw = jsNumber(n["oct"]).map(Int.init) ?? 0
                stack.append(StackEntry(st: st, oct: [-1, 0, 1].contains(octRaw) ? octRaw : 0))
            }
            chips.append(.note(stack, beats: beats))
        }

        let ragaId: String?
        if let rid = c["ragaId"] as? String, isKnownRaga(rid) { ragaId = rid } else { ragaId = nil }
        let saRaw = jsNumber(c["saOffset"])
        let saOffset = saRaw.map { ($0 == $0.rounded() && $0 >= 0 && $0 < 12) ? Int($0) : 0 } ?? 0
        let tempoRaw = jsNumber(c["tempo"]) ?? (c["tempo"] as? String).flatMap(Double.init)
        let tempo: Int
        if let t = tempoRaw, t != 0 { tempo = Int(min(120, max(30, t)).rounded()) } else { tempo = 60 }
        return Phrase(ragaId: ragaId, saOffset: saOffset, tempo: tempo,
                      loop: jsTruthy(c["loop"]), chips: chips)
    }

    /// JS `typeof v === "number"` — JSONSerialization bridges booleans to
    /// NSNumber too, so reject the boolean objCType explicitly.
    static func jsNumber(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        if String(cString: n.objCType) == "c" { return nil }
        return n.doubleValue
    }

    /// JS truthiness for JSON values.
    static func jsTruthy(_ v: Any?) -> Bool {
        guard let v = v, !(v is NSNull) else { return false }
        if let n = v as? NSNumber, String(cString: n.objCType) == "c" { return n.boolValue }
        if let n = jsNumber(v) { return n != 0 }
        if let s = v as? String { return !s.isEmpty }
        return true
    }
}

/// One scheduled note unit after phrase expansion (beats domain; the
/// player converts with beat = 60/tempo).
public struct PhraseNoteEvent: Equatable, Sendable {
    public var chipIndex: Int
    public var startBeat: Double
    public var durationBeats: Double
    public var st: String
    public var oct: Int
}

/// Phrase expansion — a faithful port of the web playback walk
/// (swStartPlayback in LoopLab, identical in Compose):
/// - a hold chip extends the pending note event by its beats;
/// - a note chip whose stack is ALL holds does the same;
/// - a gap chip closes the pending event and advances silently;
/// - within a stack holding N entries, the chip's own duration divides
///   equally over ALL N entries; a hold entry adds its share to the
///   preceding unit; the accumulated outer-hold extension lands entirely
///   on the FINAL unit.
public enum PhraseExpansion {
    public static func events(for phrase: Phrase) -> [PhraseNoteEvent] {
        struct Pending { var chip: Chip; var chipIndex: Int; var start: Double; var dur: Double }
        var pending: Pending?
        var closed: [Pending] = []
        var t = 0.0
        for (ci, ch) in phrase.chips.enumerated() {
            let allHold = ch.kind == .note && !ch.stack.isEmpty && ch.stack.allSatisfy { $0.isHold }
            if ch.kind == .hold || allHold {
                if pending != nil { pending!.dur += ch.beats }
                t += ch.beats
                continue
            }
            if let p = pending { closed.append(p); pending = nil }
            if ch.kind == .note {
                pending = Pending(chip: ch, chipIndex: ci, start: t, dur: ch.beats)
            }
            t += ch.beats
        }
        if let p = pending { closed.append(p) }

        var out: [PhraseNoteEvent] = []
        for ev in closed {
            let stack = ev.chip.stack
            let n = stack.count
            if n == 0 { continue }
            var units: [(st: String, oct: Int, shares: Int)] = []
            for entry in stack {
                if entry.isHold {
                    if !units.isEmpty { units[units.count - 1].shares += 1 }
                } else {
                    units.append((st: entry.st ?? "", oct: entry.oct, shares: 1))
                }
            }
            if units.isEmpty { continue }
            let sub = ev.chip.beats / Double(n)
            let extra = ev.dur - ev.chip.beats
            var start = ev.start
            for (ui, u) in units.enumerated() {
                var ud = Double(u.shares) * sub
                if ui == units.count - 1 { ud += extra }
                out.append(PhraseNoteEvent(chipIndex: ev.chipIndex, startBeat: start,
                                           durationBeats: ud, st: u.st, oct: u.oct))
                start += ud
            }
        }
        return out
    }
}
