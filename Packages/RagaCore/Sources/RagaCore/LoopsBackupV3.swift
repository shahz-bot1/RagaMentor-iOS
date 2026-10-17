import Foundation

/// The web loop-group palette (GROUP_COLORS), also used as the v3
/// backup colour fallback.
public enum GroupPalette {
    public static let hexes = ["#2dd4bf", "#fbbf24", "#a78bfa", "#fb7185", "#38bdf8"]
    public static func isValidHex(_ s: String) -> Bool {
        guard s.count == 7, s.hasPrefix("#") else { return false }
        return s.dropFirst().allSatisfy { $0.isHexDigit }
    }
}

/// Group sanitize — a faithful port of the web sanitizeGroups, applied
/// on LoopLab load/import/apply/delete paths there and on v3 import
/// here: drop dangling member ids and self-references; break reference
/// cycles; enforce the 2-level cap (a nested group holds loops only —
/// deeper links are cut so the sub-group surfaces to top level); drop
/// groups left with no members, cascading.
public enum GroupSanitizer {
    public static func sanitize(loopIDs: Set<UUID>,
                                groups: [LoopsBackup.PlannedGroup]) -> [LoopsBackup.PlannedGroup] {
        struct G { var id: UUID; var name: String; var colorHex: String; var members: [UUID] }
        var gs = groups.map { G(id: $0.id, name: $0.name, colorHex: $0.colorHex, members: $0.memberIDs) }
        let groupIDs = Set(gs.map(\.id))

        // 1. drop dangling ids and self-references
        for i in gs.indices {
            gs[i].members = gs[i].members.filter { $0 != gs[i].id && (loopIDs.contains($0) || groupIDs.contains($0)) }
        }
        func parentIndex(of id: UUID) -> Int? { gs.firstIndex { $0.members.contains(id) } }

        // 2. break cycles: walk up from each group; on a repeat, cut the link
        for g in gs {
            var seen: Set<UUID> = [g.id]
            var prev = g.id
            var p = parentIndex(of: g.id)
            while let pi = p {
                let pid = gs[pi].id
                if seen.contains(pid) {
                    gs[pi].members.removeAll { $0 == prev }
                    break
                }
                seen.insert(pid); prev = pid; p = parentIndex(of: pid)
            }
        }

        // 3. depth cap: groups below the top level keep only loop members
        func depth(of id: UUID) -> Int {
            var d = 0, current = id
            var seen = Set<UUID>()
            while !seen.contains(current) {
                seen.insert(current)
                guard let pi = parentIndex(of: current) else { break }
                current = gs[pi].id; d += 1
            }
            return d
        }
        for i in gs.indices where depth(of: gs[i].id) >= 1 {
            gs[i].members = gs[i].members.filter { loopIDs.contains($0) }
        }

        // 4. drop emptied groups, cascading (emptiness is checked live:
        //    scrubbing one group can empty its parent in the same pass)
        var changed = true
        while changed {
            changed = false
            for id in gs.map(\.id) {
                guard let idx = gs.firstIndex(where: { $0.id == id }),
                      gs[idx].members.isEmpty else { continue }
                gs.remove(at: idx)
                for i in gs.indices { gs[i].members.removeAll { $0 == id } }
                changed = true
            }
        }
        return gs.map { LoopsBackup.PlannedGroup(id: $0.id, name: $0.name, colorHex: $0.colorHex, memberIDs: $0.members) }
    }
}

/// Loops backup format v3 — the web LoopLab format, so loop files move
/// between web and native unchanged:
/// {app:"RagaMentor", version:3, song, exportedAt,
///  loops:[{id, name, start, end (2dp), note, swaras?}],
///  groups:[{id, name, color, members:[serials]}]}
/// Ids in the file are file-local serials (loops sorted by start get
/// 1...n, groups continue). Import replaces wholesale, checks neither
/// app nor version, and sanitizes groups like the web does.
public enum LoopsBackupV3 {
    public static func makeData(songTitle: String,
                                loops: [LoopsBackup.LoopRegionSnapshot],
                                groups: [LoopsBackup.LoopGroupSnapshot],
                                exportedAt: Date = Date(),
                                isKnownRaga: (String) -> Bool) -> Data {
        var serialByID: [UUID: Int] = [:]
        var serial = 0
        let sortedLoops = loops.sorted { $0.start < $1.start }
        for loop in sortedLoops { serial += 1; serialByID[loop.id] = serial }
        for group in groups { serial += 1; serialByID[group.id] = serial }

        let loopEntries: [JSJSON] = sortedLoops.enumerated().map { (i, loop) in
            var fields: [(String, JSJSON)] = [
                ("id", .number(Double(serialByID[loop.id] ?? 0))),
                ("name", .string(loop.name.isEmpty ? "Loop \(i + 1)" : loop.name)),
                ("start", .number((loop.start * 100).rounded() / 100)),
                ("end", .number((loop.end * 100).rounded() / 100)),
                ("note", .string(loop.note)),
            ]
            if let phrase = loop.phrase,
               let clean = PhraseSanitizer.sanitize(phrase: phrase, isKnownRaga: isKnownRaga) {
                fields.append(("swaras", .phrase(clean)))
            }
            return .object(fields)
        }
        let groupEntries: [JSJSON] = groups.map { group in
            .object([
                ("id", .number(Double(serialByID[group.id] ?? 0))),
                ("name", .string(group.name.isEmpty ? "Group" : group.name)),
                ("color", .string(GroupPalette.isValidHex(group.colorHex)
                                  ? group.colorHex : GroupPalette.hexes[0])),
                ("members", .array(group.memberIDs.compactMap {
                    serialByID[$0].map { .number(Double($0)) }
                })),
            ])
        }
        let root = JSJSON.object([
            ("app", .string("RagaMentor")),
            ("version", .number(3)),
            ("song", .string(songTitle)),
            ("exportedAt", .string(isoTimestamp(exportedAt))),
            ("loops", .array(loopEntries)),
            ("groups", .array(groupEntries)),
        ])
        return Data(root.stringify().utf8)
    }

    /// JS Date.toISOString: UTC with millisecond precision and a Z.
    static func isoTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }

    /// Plan a v3 import. Returns nil when the data is not an object with
    /// a loops array (web: unusable). Everything else is coerced or
    /// skipped per-entry, exactly as the web importer does.
    public static func planImport(data: Data, duration: Double,
                                  isKnownRaga: (String) -> Bool)
        -> (loops: [LoopsBackup.PlannedLoop], groups: [LoopsBackup.PlannedGroup])? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawLoops = root["loops"] as? [Any] else { return nil }

        var keyToID: [String: UUID] = [:]
        func idForKey(_ key: String) -> UUID {
            if let existing = keyToID[key] { return existing }
            let id = UUID(); keyToID[key] = id; return id
        }
        func key(of raw: [String: Any]) -> String? {
            guard let v = raw["id"] else { return nil }
            if let s = v as? String { return s.isEmpty ? nil : "k:" + s }
            if let n = PhraseSanitizer.jsNumber(v) { return "k:" + jsKeyString(n) }
            return nil
        }

        var loops: [LoopsBackup.PlannedLoop] = []
        for (i, rawAny) in rawLoops.enumerated() {
            guard let raw = rawAny as? [String: Any],
                  let st = jsParseFloat(raw["start"]), let en = jsParseFloat(raw["end"]),
                  st.isFinite, en.isFinite else { continue }
            let start = min(max(st, 0), duration), end = min(max(en, 0), duration)
            guard end - start >= LoopRules.minLength else { continue }
            let id = key(of: raw).map(idForKey) ?? UUID()
            let name = String(jsString(raw["name"]) ?? "Loop \(i + 1)").prefix(40)
            let phrase = raw["swaras"].map {
                PhraseSanitizer.sanitize(jsonObject: $0, isKnownRaga: isKnownRaga)
            } ?? nil
            loops.append(LoopsBackup.PlannedLoop(
                id: id, name: String(name), note: jsString(raw["note"]) ?? "",
                start: start, end: end, phrase: phrase))
        }
        let loopIDs = Set(loops.map(\.id))

        struct RawGroup { var id: UUID; var name: String; var colorHex: String; var memberKeys: [String] }
        var rawGroups: [RawGroup] = []
        let rawGroupsAny = root["groups"] as? [Any] ?? []
        for (gi, rawAny) in rawGroupsAny.enumerated() {
            guard let raw = rawAny as? [String: Any], let rawName = raw["name"] as? String
            else { continue }
            let sliced = String(rawName.prefix(40))
            let name = sliced.isEmpty ? "Group \(gi + 1)" : sliced
            let colorRaw = raw["color"] as? String ?? ""
            let color = GroupPalette.isValidHex(colorRaw)
                ? colorRaw : GroupPalette.hexes[gi % GroupPalette.hexes.count]
            let id = key(of: raw).map(idForKey) ?? UUID()
            let memberKeys = (raw["members"] as? [Any] ?? []).map { member -> String in
                if let s = member as? String { return "k:" + s }
                if let n = PhraseSanitizer.jsNumber(member) { return "k:" + jsKeyString(n) }
                return "k:"
            }
            rawGroups.append(RawGroup(id: id, name: name, colorHex: color, memberKeys: memberKeys))
        }
        let groupIDs = Set(rawGroups.map(\.id))

        var taken = Set<UUID>()
        var plannedGroups: [LoopsBackup.PlannedGroup] = []
        for g in rawGroups {
            var members: [UUID] = []
            for k in g.memberKeys {
                guard let id = keyToID[k], id != g.id, !taken.contains(id),
                      loopIDs.contains(id) || groupIDs.contains(id) else { continue }
                members.append(id); taken.insert(id)
            }
            plannedGroups.append(LoopsBackup.PlannedGroup(
                id: g.id, name: g.name, colorHex: g.colorHex, memberIDs: members))
        }

        let sanitized = GroupSanitizer.sanitize(loopIDs: loopIDs, groups: plannedGroups)
        return (loops, sanitized)
    }

    /// JS String(number) for file keys: integers without a decimal point.
    static func jsKeyString(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    /// JS parseFloat: numbers pass through; strings parse a numeric
    /// prefix; anything else is NaN.
    static func jsParseFloat(_ v: Any?) -> Double? {
        if let n = PhraseSanitizer.jsNumber(v) { return n }
        if let s = v as? String {
            let trimmed = s.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
            var prefix = ""
            var seenDot = false, seenDigit = false
            for (idx, ch) in trimmed.enumerated() {
                if ch.isNumber { prefix.append(ch); seenDigit = true }
                else if ch == "." && !seenDot { prefix.append(ch); seenDot = true }
                else if (ch == "-" || ch == "+") && idx == 0 { prefix.append(ch) }
                else { break }
            }
            return seenDigit ? Double(prefix) : nil
        }
        return nil
    }

    /// JS String(value) coercion for name/note fields: strings pass,
    /// numbers stringify, null/missing become nil (caller falls back).
    static func jsString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = PhraseSanitizer.jsNumber(v) { return jsKeyString(n) }
        if let n = v as? NSNumber, String(cString: n.objCType) == "c" {
            return n.boolValue ? "true" : "false"
        }
        return nil
    }
}

/// An ordered JSON value with a writer that matches the web export
/// byte-for-byte in structure: JSON.stringify(value, null, 2) — keys in
/// insertion order, two-space indent, integral numbers without a
/// decimal point. The loops file is platform-independent: an export
/// from web and an export from native have the same shape.
public indirect enum JSJSON {
    case object([(String, JSJSON)])
    case array([JSJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public static func phrase(_ phrase: Phrase) -> JSJSON {
        .object([
            ("ragaId", phrase.ragaId.map(JSJSON.string) ?? .null),
            ("saOffset", .number(Double(phrase.saOffset))),
            ("tempo", .number(Double(phrase.tempo))),
            ("loop", .bool(phrase.loop)),
            ("chips", .array(phrase.chips.map(chip))),
        ])
    }

    public static func chip(_ chip: Chip) -> JSJSON {
        switch chip.kind {
        case .note:
            return .object([
                ("k", .string("note")),
                ("stack", .array(chip.stack.map(entry))),
                ("beats", .number(chip.beats)),
            ])
        case .hold, .gap:
            return .object([
                ("k", .string(chip.kind.rawValue)),
                ("beats", .number(chip.beats)),
            ])
        }
    }

    public static func entry(_ entry: StackEntry) -> JSJSON {
        if entry.isHold { return .object([("hold", .bool(true))]) }
        return .object([
            ("st", .string(entry.st ?? "")),
            ("oct", .number(Double(entry.oct))),
        ])
    }

    public func stringify() -> String {
        var out = ""
        write(into: &out, level: 0)
        return out
    }

    private func write(into out: inout String, level: Int) {
        let pad = String(repeating: "  ", count: level)
        let padIn = String(repeating: "  ", count: level + 1)
        switch self {
        case .object(let fields):
            if fields.isEmpty { out += "{}"; return }
            out += "{"
            for (i, field) in fields.enumerated() {
                out += i == 0 ? "\n" : ",\n"
                out += padIn + Self.escape(field.0) + ": "
                field.1.write(into: &out, level: level + 1)
            }
            out += "\n" + pad + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                out += i == 0 ? "\n" : ",\n"
                out += padIn
                item.write(into: &out, level: level + 1)
            }
            out += "\n" + pad + "]"
        case .string(let s):
            out += Self.escape(s)
        case .number(let n):
            out += Self.formatNumber(n)
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
