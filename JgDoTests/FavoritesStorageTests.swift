import XCTest
@testable import JgDo

/// Round-trip tests for the comma-joined `Set`-in-`UserDefaults` storage
/// Favorites introduces (`favoriteLayouts`, `favoriteAppBundleIDs`).
final class FavoritesStorageTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettings.favoriteLayoutsKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.favoriteAppBundleIDsKey)
        super.tearDown()
    }

    func testFavoriteLayoutsEmptyByDefault() {
        XCTAssertTrue(AppSettings.favoriteLayouts.isEmpty)
    }

    func testFavoriteLayoutsRoundTrip() {
        AppSettings.favoriteLayouts = [.leftHalf, .maximize]
        XCTAssertEqual(AppSettings.favoriteLayouts, [.leftHalf, .maximize])
    }

    func testFavoriteLayoutsSingleValueRoundTrip() {
        AppSettings.favoriteLayouts = [.center]
        XCTAssertEqual(AppSettings.favoriteLayouts, [.center])
    }

    func testFavoriteAppBundleIDsRoundTrip() {
        AppSettings.favoriteAppBundleIDs = ["com.apple.Safari", "com.apple.Terminal"]
        XCTAssertEqual(AppSettings.favoriteAppBundleIDs, ["com.apple.Safari", "com.apple.Terminal"])
    }

    func testFavoriteAppBundleIDsEmptyByDefault() {
        XCTAssertTrue(AppSettings.favoriteAppBundleIDs.isEmpty)
    }

    func testFavoritesFirstSortIsStableWithinEachGroup() {
        // Mirrors CommandPaletteState/WorkspaceService's own comparator
        // shape — must be a strict weak ordering (both a>b and b>a false
        // whenever they're both favorite or both not), or Swift's sort
        // isn't guaranteed to produce a valid partition.
        struct Item { let name: String; let favorite: Bool }
        let items = [Item(name: "a", favorite: false), Item(name: "b", favorite: true),
                     Item(name: "c", favorite: false), Item(name: "d", favorite: true)]
        let sorted = items.sorted { $0.favorite && !$1.favorite }
        XCTAssertEqual(sorted.map(\.name), ["b", "d", "a", "c"])
    }
}
