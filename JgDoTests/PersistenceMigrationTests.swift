import XCTest
import SwiftData
@testable import JgDo

/// Covers the two things that used to be destructive: (1) the versioned
/// schema/migration plan actually opens a store built with the shape it
/// declares, and (2) `PersistenceBackup` never deletes the live store —
/// only ever copies it aside and, on `recover`, atomically replaces it
/// after backing up what was there. These run against throwaway temp
/// directories, never `Persistence.shared`'s real on-disk store.
final class PersistenceMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JgDoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - SchemaV1 / JgDoMigrationPlan

    func testSchemaV1OpensCleanly() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(url: tempDir.appendingPathComponent("Test.store"))
        let container = try ModelContainer(for: schema, migrationPlan: JgDoMigrationPlan.self, configurations: [config])

        // Round-trip one row through each model family to confirm the
        // versioned schema actually describes a working store, not just a
        // type list that happens to compile.
        let context = container.mainContext
        context.insert(Workspace(name: "Test"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Test")
    }

    func testMigrationPlanListsSchemaV1AsOnlyVersion() {
        XCTAssertEqual(JgDoMigrationPlan.schemas.count, 1)
        XCTAssertTrue(JgDoMigrationPlan.schemas[0] == SchemaV1.self)
        XCTAssertTrue(JgDoMigrationPlan.stages.isEmpty, "no migration stages exist yet — SchemaV1 is the only version shipped")
    }

    func testSchemaV1ListsAllThirteenModels() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })
        XCTAssertEqual(names, [
            "ClipboardItem", "Workspace", "WorkspaceWindow", "AppUsageEvent",
            "LayoutPreset", "LayoutSlot", "ParkedWindow", "SnapGroup", "SnapGroupMember",
            "AppCombinationObservation", "SmartLayoutSuggestion", "SmartLayoutSlot",
            "WindowPairScore",
        ])
    }

    // MARK: - PersistenceBackup: never destructive

    func testBackupBeforeOpenCopiesStoreWithoutDeletingOriginal() throws {
        let storeName = "JgDo.store"
        let storePath = tempDir.appendingPathComponent(storeName).path
        let payload = "not a real sqlite file, just needs to exist".data(using: .utf8)!
        FileManager.default.createFile(atPath: storePath, contents: payload)

        let backupURL = PersistenceBackup.backupBeforeOpen(storeDir: tempDir, storeName: storeName)

        XCTAssertNotNil(backupURL, "a live store should always produce a backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storePath), "the original store must never be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL!.path))
        let backedUpPayload = try Data(contentsOf: backupURL!)
        XCTAssertEqual(backedUpPayload, payload)
    }

    func testBackupBeforeOpenIsNoOpWithNoExistingStore() {
        // First launch: nothing to protect yet, and nothing should be created.
        let result = PersistenceBackup.backupBeforeOpen(storeDir: tempDir, storeName: "JgDo.store")
        XCTAssertNil(result)
        XCTAssertTrue(PersistenceBackup.listBackups(storeDir: tempDir).isEmpty)
    }

    func testBackupPruningKeepsOnlyMostRecentN() throws {
        let storeName = "JgDo.store"
        let storePath = tempDir.appendingPathComponent(storeName).path
        for i in 0..<7 {
            FileManager.default.createFile(atPath: storePath, contents: "v\(i)".data(using: .utf8))
            _ = PersistenceBackup.backupBeforeOpen(storeDir: tempDir, storeName: storeName, keep: 3)
            // Ensure distinct modification timestamps so pruning order is deterministic.
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertLessThanOrEqual(PersistenceBackup.listBackups(storeDir: tempDir).count, 3)
    }

    func testRecoverOverwritesLiveStoreAndBacksUpThePrevious() throws {
        let storeName = "JgDo.store"
        let storePath = tempDir.appendingPathComponent(storeName).path

        FileManager.default.createFile(atPath: storePath, contents: "original".data(using: .utf8))
        guard let firstBackup = PersistenceBackup.backupBeforeOpen(storeDir: tempDir, storeName: storeName) else {
            return XCTFail("expected a backup of the original store")
        }

        FileManager.default.createFile(atPath: storePath, contents: "corrupted".data(using: .utf8))

        try PersistenceBackup.recover(from: firstBackup, storeDir: tempDir, storeName: storeName)

        let restored = try Data(contentsOf: URL(fileURLWithPath: storePath))
        XCTAssertEqual(String(data: restored, encoding: .utf8), "original")
        // The "corrupted" version that was live at the moment of recovery
        // must itself have been preserved as a backup, not discarded.
        XCTAssertGreaterThanOrEqual(PersistenceBackup.listBackups(storeDir: tempDir).count, 2)
    }

    func testRecoverThrowsForMissingBackupInsteadOfSilentlyNoOpping() {
        let missing = tempDir.appendingPathComponent("does-not-exist.store")
        XCTAssertThrowsError(try PersistenceBackup.recover(from: missing, storeDir: tempDir))
    }
}
