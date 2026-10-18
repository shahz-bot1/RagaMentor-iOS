import Foundation

/// One Compose Studio composition: a name plus a swara phrase, with
/// the web store's timestamps (compose/index.html, `compose-studio-v1`).
/// New compositions default to Mohanam at 60 bpm (web newComp).
public struct Composition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var phrase: Phrase
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, phrase: Phrase,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.phrase = phrase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The web default composition (newComp): Untitled, Mohanam,
    /// Sa 0, 60 bpm, loop off, no chips.
    public static func makeDefault(now: Date) -> Composition {
        Composition(
            id: newID(now: now),
            name: "Untitled composition",
            phrase: Phrase(ragaId: "mohanam", saOffset: 0, tempo: 60,
                           loop: false, chips: []),
            createdAt: now, updatedAt: now)
    }

    /// Web id shape: "c" + base36(milliseconds) + a base36 random
    /// suffix (web: "c"+Date.now().toString(36)+rand).
    public static func newID(now: Date) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let suffix = Int.random(in: 0..<1_679_616) // 36^4
        return "c" + String(ms, radix: 36) + String(suffix, radix: 36)
    }
}

/// The Compose Studio file format: the export envelope, byte-
/// consistent with the web's JSON.stringify output (the standing
/// one-format rule). Import mirrors the web: envelope fields are
/// never checked, a bare composition is accepted too, and bad JSON
/// vs a failed sanitizer are distinct errors.
public enum CompositionFile {
    public enum ImportError: Error, Equatable {
        case invalidJSON
        case invalidComposition
    }

    /// `{app:"Compose Studio", version:1, kind:"composition",
    /// composition:{name, ragaId, saOffset, tempo, loop, chips}}`
    /// with keys in web insertion order.
    public static func exportData(name: String, phrase: Phrase) -> Data {
        var fields: [(String, JSJSON)] = [("name", .string(name))]
        if case .object(let phraseFields) = JSJSON.phrase(phrase) {
            fields += phraseFields
        }
        let root = JSJSON.object([
            ("app", .string("Compose Studio")),
            ("version", .number(1)),
            ("kind", .string("composition")),
            ("composition", .object(fields)),
        ])
        return Data(root.stringify().utf8)
    }

    /// Parse an imported file. On success returns the composition's
    /// name (defaulting to Untitled when absent) and its sanitized
    /// phrase; the caller assigns a fresh id, as the web does.
    public static func parseImport(
        data: Data, isKnownRaga: (String) -> Bool
    ) -> Result<(name: String, phrase: Phrase), ImportError> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.invalidJSON)
        }
        guard let phrase = PhraseSanitizer.sanitize(
            jsonObject: obj, isKnownRaga: isKnownRaga) else {
            return .failure(.invalidComposition)
        }
        var root = obj as? [String: Any]
        if let envelope = root?["composition"] as? [String: Any] { root = envelope }
        let rawName = root?["name"] as? String
        let name = (rawName?.isEmpty == false) ? rawName! : "Untitled composition"
        return .success((name: name, phrase: phrase))
    }

    /// Export filename slug (web slugify): the registry slug rules.
    public static func fileSlug(for name: String) -> String {
        let slug = RagaCatalog.registryId(forName: name)
        return slug.isEmpty ? "composition" : slug
    }
}
