import XCTest
import SwiftData
@testable import JgDo

/// Covers the pure, DI-friendly pieces of the clipboard privacy pass:
/// content-hash computation/dedup semantics and `ClipboardPrivacyService`'s
/// retention/storage-cap/pause/exclusion logic. Deliberately does NOT
/// exercise `ClipboardService` itself (a singleton bound to
/// `Persistence.shared`'s real on-disk store and a live `NSPasteboard`) —
/// see the plan's C2 note on `PersistenceProviding` for why the singleton
/// itself isn't test-isolated yet; these tests validate the logic it
/// delegates to instead.
final class ClipboardTrimDedupTests: XCTestCase {

    // MARK: - Content hash

    func testIdenticalTextProducesIdenticalHash() {
        let a = ClipboardItem.computeContentHash(kind: .text, text: "hello", imageData: nil, filePaths: [])
        let b = ClipboardItem.computeContentHash(kind: .text, text: "hello", imageData: nil, filePaths: [])
        XCTAssertEqual(a, b)
    }

    func testDifferentTextProducesDifferentHash() {
        let a = ClipboardItem.computeContentHash(kind: .text, text: "hello", imageData: nil, filePaths: [])
        let b = ClipboardItem.computeContentHash(kind: .text, text: "goodbye", imageData: nil, filePaths: [])
        XCTAssertNotEqual(a, b)
    }

    func testSameTextDifferentKindProducesDifferentHash() {
        // Guards against a hash collision between e.g. a "file" whose sole
        // path happens to match a "text" item's content.
        let asText = ClipboardItem.computeContentHash(kind: .text, text: "/tmp/a", imageData: nil, filePaths: [])
        let asFile = ClipboardItem.computeContentHash(kind: .file, text: nil, imageData: nil, filePaths: ["/tmp/a"])
        XCTAssertNotEqual(asText, asFile)
    }

    func testIdenticalImageDataProducesIdenticalHash() {
        let data = Data([0x01, 0x02, 0x03, 0xFF])
        let a = ClipboardItem.computeContentHash(kind: .image, text: nil, imageData: data, filePaths: [])
        let b = ClipboardItem.computeContentHash(kind: .image, text: nil, imageData: data, filePaths: [])
        XCTAssertEqual(a, b)
    }

    func testRecomputeContentHashSetsFieldOnInstance() {
        let item = ClipboardItem(kind: .text, text: "round trip")
        XCTAssertNil(item.contentHash)
        item.recomputeContentHash()
        XCTAssertNotNil(item.contentHash)
        XCTAssertEqual(item.contentHash, ClipboardItem.computeContentHash(kind: .text, text: "round trip", imageData: nil, filePaths: []))
    }

    // MARK: - ClipboardPrivacyService: retention

    func testExpiredItemsFiltersByAgeAndPin() {
        let privacy = ClipboardPrivacyService.shared
        let originalRetention = privacy.retentionDays
        defer { privacy.retentionDays = originalRetention }
        privacy.retentionDays = 7

        let old = ClipboardItem(kind: .text, text: "old")
        old.createdAt = Date().addingTimeInterval(-10 * 86400)
        let oldPinned = ClipboardItem(kind: .text, text: "old pinned")
        oldPinned.createdAt = Date().addingTimeInterval(-10 * 86400)
        oldPinned.isPinned = true
        let recent = ClipboardItem(kind: .text, text: "recent")
        recent.createdAt = Date()

        let expired = privacy.expiredItems(in: [old, oldPinned, recent])
        XCTAssertEqual(expired.map(\.text), ["old"], "pinned items must survive retention regardless of age")
    }

    func testExpiredItemsEmptyWhenRetentionDisabled() {
        let privacy = ClipboardPrivacyService.shared
        let originalRetention = privacy.retentionDays
        defer { privacy.retentionDays = originalRetention }
        privacy.retentionDays = 0

        let ancient = ClipboardItem(kind: .text, text: "ancient")
        ancient.createdAt = Date().addingTimeInterval(-365 * 86400)
        XCTAssertTrue(privacy.expiredItems(in: [ancient]).isEmpty)
    }

    // MARK: - ClipboardPrivacyService: storage cap

    func testItemsExceedingStorageCapDropsOldestUnpinnedFirst() {
        let privacy = ClipboardPrivacyService.shared
        let originalCap = privacy.maxStorageBytes
        defer { privacy.maxStorageBytes = originalCap }

        let oldest = ClipboardItem(kind: .text, text: String(repeating: "a", count: 100))
        oldest.createdAt = Date().addingTimeInterval(-300)
        let middle = ClipboardItem(kind: .text, text: String(repeating: "b", count: 100))
        middle.createdAt = Date().addingTimeInterval(-200)
        let newest = ClipboardItem(kind: .text, text: String(repeating: "c", count: 100))
        newest.createdAt = Date().addingTimeInterval(-100)

        // Total ~300 bytes; cap at 150 forces dropping the oldest first.
        privacy.maxStorageBytes = 150
        let toDrop = privacy.itemsExceedingStorageCap(in: [oldest, middle, newest])
        XCTAssertEqual(toDrop.first?.text, oldest.text)
    }

    func testItemsExceedingStorageCapNeverDropsPinned() {
        let privacy = ClipboardPrivacyService.shared
        let originalCap = privacy.maxStorageBytes
        defer { privacy.maxStorageBytes = originalCap }

        let pinnedOld = ClipboardItem(kind: .text, text: String(repeating: "a", count: 1000))
        pinnedOld.createdAt = Date().addingTimeInterval(-500)
        pinnedOld.isPinned = true

        privacy.maxStorageBytes = 10 // far below even one item's size
        let toDrop = privacy.itemsExceedingStorageCap(in: [pinnedOld])
        XCTAssertTrue(toDrop.isEmpty, "a pinned item must never be selected for removal, even if it alone exceeds the cap")
    }

    func testItemsExceedingStorageCapEmptyWhenUnlimited() {
        let privacy = ClipboardPrivacyService.shared
        let originalCap = privacy.maxStorageBytes
        defer { privacy.maxStorageBytes = originalCap }
        privacy.maxStorageBytes = 0

        let huge = ClipboardItem(kind: .text, text: String(repeating: "a", count: 1_000_000))
        XCTAssertTrue(privacy.itemsExceedingStorageCap(in: [huge]).isEmpty)
    }

    // MARK: - ClipboardPrivacyService: pause

    func testPauseForFiveMinutesReportsIsPaused() {
        let privacy = ClipboardPrivacyService.shared
        defer { privacy.resume() }
        privacy.pause(for: .fiveMinutes)
        XCTAssertTrue(privacy.isPaused)
        XCTAssertNotNil(privacy.pausedUntil)
        XCTAssertNotEqual(privacy.pausedUntil, .distantFuture)
    }

    func testPauseUntilResumedUsesDistantFutureSentinel() {
        let privacy = ClipboardPrivacyService.shared
        defer { privacy.resume() }
        privacy.pause(for: .untilResumed)
        XCTAssertTrue(privacy.isPaused)
        XCTAssertEqual(privacy.pausedUntil, .distantFuture)
    }

    func testResumeClearsPause() {
        let privacy = ClipboardPrivacyService.shared
        privacy.pause(for: .untilResumed)
        privacy.resume()
        XCTAssertFalse(privacy.isPaused)
        XCTAssertNil(privacy.pausedUntil)
    }

    func testNotPausedByDefault() {
        let privacy = ClipboardPrivacyService.shared
        privacy.resume() // ensure clean state regardless of test order
        XCTAssertFalse(privacy.isPaused)
    }

    // MARK: - ClipboardPrivacyService: per-app exclusion

    func testExcludedBundleIDIsRespected() {
        let privacy = ClipboardPrivacyService.shared
        let bundleID = "com.example.TestExclusion"
        defer { privacy.setExcluded(false, bundleID: bundleID) }

        XCTAssertFalse(privacy.isExcluded(bundleID: bundleID))
        privacy.setExcluded(true, bundleID: bundleID)
        XCTAssertTrue(privacy.isExcluded(bundleID: bundleID))
        privacy.setExcluded(false, bundleID: bundleID)
        XCTAssertFalse(privacy.isExcluded(bundleID: bundleID))
    }

    func testNilBundleIDIsNeverExcluded() {
        XCTAssertFalse(ClipboardPrivacyService.shared.isExcluded(bundleID: nil))
    }

    // MARK: - Storage usage formatting

    func testStorageUsageBytesSumsAcrossItems() {
        let a = ClipboardItem(kind: .text, text: "12345") // 5 bytes
        let b = ClipboardItem(kind: .text, text: "1234567890") // 10 bytes
        let total = ClipboardPrivacyService.shared.storageUsageBytes(items: [a, b])
        XCTAssertEqual(total, 15)
    }
}
