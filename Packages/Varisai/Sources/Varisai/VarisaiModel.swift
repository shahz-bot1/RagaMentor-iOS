import Foundation

/// One varisai pattern: a flat token list for playback and the
/// grouped display lines. Verified at generation time (and in
/// tests): the display lines flatten exactly to the note list.
public struct VarisaiPattern: Equatable, Sendable {
    public let title: String
    public let sub: String
    /// Laya grouping description (24 patterns), verbatim from the
    /// data — e.g. "1234 5678" or a two-part "… and …" string.
    public let laya: String?
    /// Alankaram tala string (7 patterns) — e.g. "I4 0 I4 I4".
    public let tala: String?
    public let notes: [String]
    /// Display lines → groups → tokens.
    public let dlines: [[[String]]]

    public init(title: String, sub: String, laya: String?, tala: String?,
                notes: [String], dlines: [[[String]]]) {
        self.title = title
        self.sub = sub
        self.laya = laya
        self.tala = tala
        self.notes = notes
        self.dlines = dlines
    }
}

/// One varisai lesson (Sarali, Janta, Dhattu, Alankaram, and the
/// three Sthayi lessons) — all in Mayamalavagowla, no raga choice.
public struct VarisaiLesson: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let num: Int
    public let desc: String
    public let raga: String
    public let patterns: [VarisaiPattern]

    public init(id: String, name: String, num: Int, desc: String,
                raga: String, patterns: [VarisaiPattern]) {
        self.id = id
        self.name = name
        self.num = num
        self.desc = desc
        self.raga = raga
        self.patterns = patterns
    }
}

/// The lesson catalog, generated into LessonsData.swift from the
/// mock repo (the notation source of truth).
public enum VarisaiData {
    public static let lessons: [VarisaiLesson] =
        [sarali, janta, dhattu, alankaram, mandhra, madhya, mel]
}
