import Foundation
import SwiftData

/// Persistence boundary for the song library (PARITY-PLAN §3.1).
/// The app owns one store; previews and tests substitute an in-memory
/// one. Feature code reaches the store's container/context through
/// SwiftUI's environment, exactly as the views already do.
public protocol SongStore: AnyObject {
    var container: ModelContainer { get }
}

/// SwiftData-backed store: Song / LoopRegion / LoopGroup, fully
/// on-device (PLAN §3 decision 8).
public final class SwiftDataSongStore: SongStore {
    public let container: ModelContainer

    public init(inMemory: Bool = false) throws {
        container = try ModelContainer(
            for: Song.self, LoopRegion.self, LoopGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }
}
