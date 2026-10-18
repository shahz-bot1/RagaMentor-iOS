import Foundation
import RagaCore

/// Compose Studio storage (web `compose-studio-v1`): the whole
/// composition list saved as one object on every change. The
/// protocol lives here with the other stores; the implementation is
/// UserDefaults-backed, mirroring the web's whole-object saves.
public protocol CompositionStore: AnyObject {
    /// All compositions, most recently updated first (web list order).
    func all() -> [Composition]
    @discardableResult
    func createDefault() -> Composition
    @discardableResult
    func appendImported(name: String, phrase: Phrase) -> Composition
    /// Replace a composition's phrase and stamp updatedAt (editor saves).
    func save(phrase: Phrase, for id: String)
    /// Rename and stamp updatedAt (the web title edit saves live).
    func rename(id: String, to name: String)
    func delete(id: String)
}

public final class UserDefaultsCompositionStore: CompositionStore {
    private let defaults: UserDefaults
    private let key = "compose-studio-v1"
    private let now: () -> Date

    public init(defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    public func all() -> [Composition] {
        load().sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func createDefault() -> Composition {
        let comp = Composition.makeDefault(now: now())
        persist(load() + [comp])
        return comp
    }

    @discardableResult
    public func appendImported(name: String, phrase: Phrase) -> Composition {
        let t = now()
        let comp = Composition(id: Composition.newID(now: t), name: name,
                               phrase: phrase, createdAt: t, updatedAt: t)
        persist(load() + [comp])
        return comp
    }

    public func save(phrase: Phrase, for id: String) {
        var comps = load()
        guard let i = comps.firstIndex(where: { $0.id == id }) else { return }
        comps[i].phrase = phrase
        comps[i].updatedAt = now()
        persist(comps)
    }

    public func rename(id: String, to name: String) {
        var comps = load()
        guard let i = comps.firstIndex(where: { $0.id == id }) else { return }
        comps[i].name = name
        comps[i].updatedAt = now()
        persist(comps)
    }

    public func delete(id: String) {
        persist(load().filter { $0.id != id })
    }

    // MARK: - Whole-list persistence (web parity)

    private func load() -> [Composition] {
        guard let data = defaults.data(forKey: key),
              let comps = try? JSONDecoder().decode([Composition].self, from: data)
        else { return [] }
        return comps
    }

    private func persist(_ comps: [Composition]) {
        if let data = try? JSONEncoder().encode(comps) {
            defaults.set(data, forKey: key)
        }
    }
}
