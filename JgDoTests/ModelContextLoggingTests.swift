import XCTest
import SwiftData
@testable import JgDo

/// `ModelContext.fetchLogged` is the shared helper C3 introduced to replace
/// the `(try? ctx.fetch(...)) ?? []` pattern repeated across every
/// `reload()`-style method in the app — this pins its happy path (results
/// come back unchanged) since the failure path isn't reachable without a
/// genuinely broken container.
@MainActor
final class ModelContextLoggingTests: XCTestCase {

    func testFetchLoggedReturnsResultsOnSuccess() throws {
        let persistence = InMemoryPersistence()
        let workspace = Workspace(name: "Test")
        persistence.context.insert(workspace)
        persistence.save()

        let results = persistence.context.fetchLogged(FetchDescriptor<Workspace>(), using: AppLog.workspace)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Test")
    }

    func testFetchLoggedReturnsEmptyArrayWhenNothingStored() {
        let persistence = InMemoryPersistence()
        let results = persistence.context.fetchLogged(FetchDescriptor<Workspace>(), using: AppLog.workspace)
        XCTAssertTrue(results.isEmpty)
    }
}
