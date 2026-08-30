import XCTest
@testable import JgDo

/// Covers `FileSearchService`'s pure, dependency-free logic — predicate
/// construction, scope resolution, and path display formatting — without
/// touching a live `NSMetadataQuery`/Spotlight index, which isn't safe to
/// depend on on a test runner (index state varies by machine, may not be
/// finished indexing, etc). Ranking itself (`FuzzyMatch.score`) already has
/// its own coverage elsewhere; this file only exercises the glue code
/// around it that's specific to `FileSearchService`.
final class FileSearchServiceTests: XCTestCase {

    // MARK: - predicate(forQuery:)

    func testQueryPredicateMatchesFileNameSubstring() {
        let predicate = FileSearchService.predicate(forQuery: "invoice")
        let item = ["kMDItemFSName": "2024-invoice.pdf", "kMDItemDisplayName": "2024-invoice.pdf"] as NSDictionary
        XCTAssertTrue(predicate.evaluate(with: item))
    }

    func testQueryPredicateIsCaseInsensitive() {
        let predicate = FileSearchService.predicate(forQuery: "INVOICE")
        let item = ["kMDItemFSName": "2024-invoice.pdf", "kMDItemDisplayName": "2024-invoice.pdf"] as NSDictionary
        XCTAssertTrue(predicate.evaluate(with: item))
    }

    func testQueryPredicateRejectsNonMatchingName() {
        let predicate = FileSearchService.predicate(forQuery: "invoice")
        let item = ["kMDItemFSName": "vacation-photo.jpg", "kMDItemDisplayName": "vacation-photo.jpg"] as NSDictionary
        XCTAssertFalse(predicate.evaluate(with: item))
    }

    func testQueryPredicateMatchesOnDisplayNameEvenIfFSNameDiffers() {
        // OR'd across both keys — a display name match alone should pass,
        // matching how Spotlight's display name can differ from the raw
        // filename (extensions hidden, localized names, etc).
        let predicate = FileSearchService.predicate(forQuery: "report")
        let item = ["kMDItemFSName": "doc_991.pdf", "kMDItemDisplayName": "Quarterly Report.pdf"] as NSDictionary
        XCTAssertTrue(predicate.evaluate(with: item))
    }

    // MARK: - recentFilesPredicate()

    func testRecentFilesPredicateExcludesFolders() {
        let predicate = FileSearchService.recentFilesPredicate()
        let folderItem = ["kMDItemContentTypeTree": "public.folder"] as NSDictionary
        XCTAssertFalse(predicate.evaluate(with: folderItem))
    }

    func testRecentFilesPredicateIncludesNonFolders() {
        let predicate = FileSearchService.recentFilesPredicate()
        let fileItem = ["kMDItemContentTypeTree": "public.pdf"] as NSDictionary
        XCTAssertTrue(predicate.evaluate(with: fileItem))
    }

    // MARK: - displayFolderPath(for:)

    func testDisplayFolderPathAbbreviatesHomeDirectory() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: "\(home)/Documents/Projects/notes.txt")
        XCTAssertEqual(FileSearchService.displayFolderPath(for: url), "~/Documents/Projects")
    }

    func testDisplayFolderPathLeavesNonHomePathsAbsolute() {
        let url = URL(fileURLWithPath: "/Volumes/External/archive.zip")
        XCTAssertEqual(FileSearchService.displayFolderPath(for: url), "/Volumes/External")
    }

    // MARK: - searchScopes

    func testSearchScopesAlwaysIncludesCoreFolders() {
        let scopes = FileSearchService.searchScopes
        let home = NSHomeDirectory()
        XCTAssertTrue(scopes.contains("\(home)/Desktop"))
        XCTAssertTrue(scopes.contains("\(home)/Documents"))
        XCTAssertTrue(scopes.contains("\(home)/Downloads"))
    }

    func testSearchScopesOnlyIncludesProjectsFolderIfItExists() {
        let scopes = FileSearchService.searchScopes
        let projects = "\(NSHomeDirectory())/Projects"
        XCTAssertEqual(scopes.contains(projects), FileManager.default.fileExists(atPath: projects))
    }
}
