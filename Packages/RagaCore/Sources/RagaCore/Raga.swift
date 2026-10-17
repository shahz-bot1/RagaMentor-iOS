import Foundation

/// One raga: scale data plus the browser metadata (nil for editor-table
/// entries that carry no browser fields).
public struct Raga: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var aro: [String]
    public var ava: [String]
    public var allied: [String]
    public var melakartaNumber: Int?
    public var parentMelakarta: String?
    public var chakra: String?
    public var jati: String?
    public var isHindustani: Bool
    public var thaat: String?

    public init(id: String, name: String, aro: [String], ava: [String],
                allied: [String] = [], melakartaNumber: Int? = nil,
                parentMelakarta: String? = nil, chakra: String? = nil,
                jati: String? = nil, isHindustani: Bool = false, thaat: String? = nil) {
        self.id = id; self.name = name; self.aro = aro; self.ava = ava
        self.allied = allied; self.melakartaNumber = melakartaNumber
        self.parentMelakarta = parentMelakarta; self.chakra = chakra
        self.jati = jati; self.isHindustani = isHindustani; self.thaat = thaat
    }
}

/// The raga catalog: the 87-raga browser registry (generated in
/// RagaCatalogData.swift) and the curated 10-raga editor table ported
/// verbatim from the web composers. The editor resolves ragas against
/// the curated table plus the personal registry — never the 87 directly.
public enum RagaCatalog {
    public static let curated: [Raga] = [
        Raga(id: "mohanam", name: "Mohanam",
             aro: ["S", "R2", "G3", "P", "D2"], ava: ["S", "D2", "P", "G3", "R2"]),
        Raga(id: "hamsadhvani", name: "Hamsadhvani",
             aro: ["S", "R2", "G3", "P", "N3"], ava: ["S", "N3", "P", "G3", "R2"]),
        Raga(id: "shankarabharanam", name: "Shankarabharanam",
             aro: ["S", "R2", "G3", "M1", "P", "D2", "N3"], ava: ["S", "N3", "D2", "P", "M1", "G3", "R2"]),
        Raga(id: "kalyani", name: "Kalyani",
             aro: ["S", "R2", "G3", "M2", "P", "D2", "N3"], ava: ["S", "N3", "D2", "P", "M2", "G3", "R2"]),
        Raga(id: "mayamalavagowla", name: "Mayamalavagowla",
             aro: ["S", "R1", "G3", "M1", "P", "D1", "N3"], ava: ["S", "N3", "D1", "P", "M1", "G3", "R1"]),
        Raga(id: "hindolam", name: "Hindolam",
             aro: ["S", "G2", "M1", "D1", "N2"], ava: ["S", "N2", "D1", "M1", "G2"]),
        Raga(id: "abhogi", name: "Abhogi",
             aro: ["S", "R2", "G2", "M1", "D2"], ava: ["S", "D2", "M1", "G2", "R2"]),
        Raga(id: "bhairavi", name: "Bhairavi",
             aro: ["S", "R2", "G2", "M1", "P", "D2", "N2"], ava: ["S", "N2", "D1", "P", "M1", "G2", "R2"]),
        Raga(id: "aanandabhairavi", name: "Aananda Bhairavi",
             aro: ["S", "G2", "R2", "G2", "M1", "P", "D2", "P", "N2"], ava: ["S", "N2", "D2", "P", "M1", "G2", "R2"]),
        Raga(id: "shubhapanthuvarali", name: "Shubhapanthuvarali",
             aro: ["S", "R1", "G2", "M2", "P", "D1", "N3"], ava: ["S", "N3", "D1", "P", "M2", "G2", "R1"]),
    ]

    public static func catalogRaga(id: String) -> Raga? { all.first { $0.id == id } }
    public static func curatedRaga(id: String) -> Raga? { curated.first { $0.id == id } }

    /// Web normAro/normAva: strip apostrophes, then drop a trailing "S"
    /// when the scale has more than one entry.
    public static func normalized(_ scale: [String]) -> [String] {
        var x = scale.map { $0.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2032}", with: "") }
        if x.count > 1 && x.last == "S" { x.removeLast() }
        return x
    }

    public static func signature(aro: [String], ava: [String]) -> String {
        normalized(aro).joined(separator: " ") + "|" + normalized(ava).joined(separator: " ")
    }

    public static func signature(of raga: Raga) -> String { signature(aro: raga.aro, ava: raga.ava) }

    /// Web resolveRagaId: a pick resolves to a curated-table raga by
    /// scale signature first, then by name (case-insensitive).
    public static func resolveCurated(name: String, aro: [String], ava: [String]) -> Raga? {
        let sig = signature(aro: aro, ava: ava)
        if let hit = curated.first(where: { signature(of: $0) == sig }) { return hit }
        return curated.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Picker order for a raga: arohana order (deduped), then
    /// avarohana-only sthanas (web ragaPickerList).
    public static func pickerList(for raga: Raga) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in raga.aro + raga.ava where !seen.contains(s) {
            seen.insert(s); out.append(s)
        }
        return out
    }

    /// Personal-registry id for a picked raga name (web registryIdFor:
    /// lowercase, runs of non-[a-z0-9] collapse to one dash, dashes
    /// trimmed from both ends).
    public static func registryId(forName name: String) -> String {
        let lowered = (name.isEmpty ? "raga" : name).lowercased()
        var slug = ""
        var lastWasDash = true // trims leading dashes as we go
        for ch in lowered {
            let scalars = ch.unicodeScalars
            let isASCIIAlnum = scalars.count == 1 && scalars.first.map {
                (97...122).contains($0.value) || (48...57).contains($0.value)
            } == true
            if isASCIIAlnum {
                slug.append(ch); lastWasDash = false
            } else if !lastWasDash {
                slug.append("-"); lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return "rb-" + slug
    }
}
