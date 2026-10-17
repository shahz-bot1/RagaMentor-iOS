import Foundation
import RagaCore

/// The RagaLibrary store: UserDefaults-backed, keys mirroring the web's
/// localStorage names. One source of truth for recents, favourites and
/// the personal registry (the web mirrored favourites into a second key
/// and synced; here the sync rules run against this single store).
/// The registry is stored as an ordered list: web object-key order is
/// insertion order, and the editor dropdown shows entries in that order.
public final class DefaultRagaLibrary: RagaLibrary {
    private let defaults: UserDefaults

    private enum Key {
        static let recents = "raga-recents-v1"
        static let registry = "raga-registry-v1"
        static let favData = "raga-fav-data-v1"
        static let favourites = "raga-favs"
    }

    private struct RegistryRecord: Codable {
        var id: String
        var entry: RagaRegistryEntry
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Stored state

    private var recentIDs: [String] {
        get { read([String].self, Key.recents) ?? [] }
        set { write(newValue, Key.recents) }
    }
    private var registryRecords: [RegistryRecord] {
        get { read([RegistryRecord].self, Key.registry) ?? [] }
        set { write(newValue, Key.registry) }
    }
    private var registry: [String: RagaRegistryEntry] {
        Dictionary(uniqueKeysWithValues: registryRecords.map { ($0.id, $0.entry) })
    }
    private func setRegistry(id: String, entry: RagaRegistryEntry?) {
        var records = registryRecords
        if let entry {
            if let idx = records.firstIndex(where: { $0.id == id }) {
                records[idx].entry = entry // existing key keeps its position (JS semantics)
            } else {
                records.append(RegistryRecord(id: id, entry: entry))
            }
        } else {
            records.removeAll { $0.id == id }
        }
        registryRecords = records
    }
    /// The favourites' scale-data mirror (web raga-fav-data-v1):
    /// sourceId → entry, written when a raga is favourited in the browser.
    private var favData: [String: RagaRegistryEntry] {
        get { read([String: RagaRegistryEntry].self, Key.favData) ?? [:] }
        set { write(newValue, Key.favData) }
    }
    private var favouriteIDs: [String] {
        get { read([String].self, Key.favourites) ?? [] }
        set { write(newValue, Key.favourites) }
    }

    private func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - RagaLibrary

    public func raga(id: String) -> Raga? {
        if let curated = RagaCatalog.curatedRaga(id: id) { return curated }
        return registry[id]?.asRaga(id: id)
    }

    public func recentRagas() -> [Raga] {
        recentIDs.compactMap { raga(id: $0) }
    }

    public func registryRagas() -> [Raga] {
        registryRecords.map { $0.entry.asRaga(id: $0.id) }
    }

    public func favourites() -> [Raga] {
        favouriteIDs.compactMap { RagaCatalog.catalogRaga(id: $0) }
    }

    public func isFavourite(sourceId: String) -> Bool {
        favouriteIDs.contains(sourceId)
    }

    public func recordUse(id: String) {
        guard !id.isEmpty else { return }
        recentIDs = Array(([id] + recentIDs.filter { $0 != id }).prefix(5))
    }

    @discardableResult
    public func adoptPick(_ pick: RagaPick) -> String {
        if let hit = RagaCatalog.resolveCurated(name: pick.name, aro: pick.aro, ava: pick.ava) {
            return hit.id
        }
        let id = RagaCatalog.registryId(forName: pick.name)
        // Web registerPickedRaga: an existing entry is rewritten when the
        // source is a pick (always, here); a fresh entry is created.
        setRegistry(id: id, entry: RagaRegistryEntry(
            name: pick.name,
            aro: RagaCatalog.normalized(pick.aro),
            ava: RagaCatalog.normalized(pick.ava),
            src: "pick", srcId: pick.sourceId))
        return id
    }

    public func setFavourite(_ raga: Raga, favourited: Bool) {
        var ids = favouriteIDs
        var data = favData
        if favourited {
            if !ids.contains(raga.id) { ids.append(raga.id) }
            data[raga.id] = RagaRegistryEntry(name: raga.name, aro: raga.aro, ava: raga.ava,
                                              src: "fav", srcId: raga.id)
        } else {
            ids.removeAll { $0 == raga.id }
            data.removeValue(forKey: raga.id)
        }
        favouriteIDs = ids
        favData = data
        syncFavRegistry()
    }

    /// Web syncFavRegistry: mirror favourites into the registry as
    /// src:"fav" entries (skipping ragas that resolve to the curated
    /// table and entries that already exist); remove src:"fav" entries
    /// whose source favourite is gone. src:"pick" entries are kept.
    private func syncFavRegistry() {
        let data = favData
        for (srcId, entry) in data {
            if RagaCatalog.resolveCurated(name: entry.name, aro: entry.aro, ava: entry.ava) != nil {
                continue
            }
            let id = RagaCatalog.registryId(forName: entry.name)
            if registry[id] == nil {
                setRegistry(id: id, entry: RagaRegistryEntry(
                    name: entry.name,
                    aro: RagaCatalog.normalized(entry.aro),
                    ava: RagaCatalog.normalized(entry.ava),
                    src: "fav", srcId: srcId))
            }
        }
        for record in registryRecords where record.entry.src == "fav" {
            if let srcId = record.entry.srcId, data[srcId] == nil {
                setRegistry(id: record.id, entry: nil)
            }
        }
    }

    public func dropdownGroups(currentId: String?) -> RagaDropdownGroups {
        let current = currentId.flatMap { raga(id: $0) }
        return RagaDropdownGroups.make(recents: recentRagas(),
                                       registry: registryRagas(),
                                       current: current)
    }
}
