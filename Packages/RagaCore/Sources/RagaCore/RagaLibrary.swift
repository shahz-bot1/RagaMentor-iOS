import Foundation

/// A personal-registry entry (web raga-registry-v1): a raga adopted from
/// a RagaBrowser pick or mirrored from a browser favourite, keyed by an
/// "rb-<slug>" id in the store.
public struct RagaRegistryEntry: Codable, Equatable, Sendable {
    public var name: String
    public var aro: [String]
    public var ava: [String]
    public var src: String // "pick" | "fav"
    public var srcId: String?

    public init(name: String, aro: [String], ava: [String], src: String, srcId: String?) {
        self.name = name; self.aro = aro; self.ava = ava; self.src = src; self.srcId = srcId
    }

    public func asRaga(id: String) -> Raga {
        Raga(id: id, name: name, aro: aro, ava: ava)
    }
}

/// A typed raga pick — the native replacement for the web's
/// localStorage pick mailbox. RagaBrowser (P3) produces one; editors
/// consume it through RagaLibrary.adoptPick.
public struct RagaPick: Equatable, Sendable {
    public var sourceId: String?
    public var name: String
    public var aro: [String]
    public var ava: [String]

    public init(sourceId: String?, name: String, aro: [String], ava: [String]) {
        self.sourceId = sourceId; self.name = name; self.aro = aro; self.ava = ava
    }
}

/// The editor raga dropdown's groups (web ragaOptionsHTML): Recents
/// first, then the "Favourites" group — which on web lists the personal
/// registry entries. Groups are deduped (first group wins) and the
/// current raga is pinned at the front of Recents when it appears in
/// neither group.
public struct RagaDropdownGroups: Equatable, Sendable {
    public var recents: [Raga]
    public var favourites: [Raga]

    public init(recents: [Raga], favourites: [Raga]) {
        self.recents = recents; self.favourites = favourites
    }

    public static func make(recents: [Raga], registry: [Raga], current: Raga?) -> RagaDropdownGroups {
        let seen = Set(recents.map(\.id))
        let favs = registry.filter { !seen.contains($0.id) }
        var rec = recents
        if let current, !seen.contains(current.id), !favs.contains(where: { $0.id == current.id }) {
            rec = [current] + rec
        }
        return RagaDropdownGroups(recents: rec, favourites: favs)
    }
}

/// The shared raga-selection service — ONE source of truth for recents,
/// favourites, the personal registry and pick resolution, replacing the
/// web's mirrored localStorage keys. The protocol lives in RagaCore;
/// the store implementation lives in PersistenceKit.
public protocol RagaLibrary: AnyObject {
    /// Editor lookup: curated table ∪ personal registry (web ragaById).
    func raga(id: String) -> Raga?
    /// Recents (MRU, cap 5), resolved to ragas; unknown ids dropped.
    func recentRagas() -> [Raga]
    /// All personal-registry entries as ragas.
    func registryRagas() -> [Raga]
    /// Browser favourites in insertion order, resolved against the
    /// 87-raga catalog.
    func favourites() -> [Raga]
    func isFavourite(sourceId: String) -> Bool
    /// Move a raga to the front of recents (web noteRagaUsed).
    func recordUse(id: String)
    /// Adopt a browser pick (web registerPickedRaga with src "pick"):
    /// resolves to a curated id when the scale signature or name matches
    /// the table; otherwise stores/refreshes a registry entry. Returns
    /// the id the editor should select.
    @discardableResult
    func adoptPick(_ pick: RagaPick) -> String
    /// Favourite or unfavourite a catalog raga from the browser:
    /// maintains the favourite set, its scale-data mirror, and the
    /// registry bridge (web syncFavRegistry rules — unfavouriting
    /// removes src:"fav" registry entries but keeps src:"pick" ones;
    /// ragas that resolve to the curated table never enter the registry).
    func setFavourite(_ raga: Raga, favourited: Bool)
    /// The dropdown groups for an editor whose current raga is given.
    func dropdownGroups(currentId: String?) -> RagaDropdownGroups
}
