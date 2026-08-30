import SwiftData
@testable import JgDo

/// A `PersistenceProviding` backed by an in-memory `ModelContainer`, for
/// tests that need to exercise real SwiftData insert/fetch/cascade-delete
/// behavior without touching `Persistence.shared`'s actual on-disk store
/// (which would mean either polluting the developer's real clipboard/
/// workspace history or fighting over shared mutable state between tests).
@MainActor
final class InMemoryPersistence: PersistenceProviding {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // Force-unwrap is fine here: an in-memory container with no
        // migration to perform should never fail to build, and if it
        // somehow did, every test using this helper should fail loudly
        // rather than silently running against nothing.
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    func save() {
        try? context.save()
    }
}
