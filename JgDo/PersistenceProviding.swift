import SwiftData

/// The slice of `Persistence` that services actually depend on. Exists so
/// a service can be constructed against an isolated (in-memory, per-test)
/// store instead of `Persistence.shared`'s real on-disk one — without
/// DI-ifying every service wholesale, just the ones whose persistence
/// interactions are worth exercising in an integration test (currently
/// `WorkspaceService`; see `JgDoTests/InMemoryPersistence.swift`).
@MainActor
protocol PersistenceProviding: AnyObject {
    var context: ModelContext { get }
    func save()
}

extension Persistence: PersistenceProviding {}
