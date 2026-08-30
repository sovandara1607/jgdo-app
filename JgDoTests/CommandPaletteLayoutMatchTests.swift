import XCTest
@testable import JgDo

/// `CommandPaletteState.matchedLayout(in:)` is pure text-in/`WindowLayout`-
/// out — no AppKit, no live windows — covering the exact alias set the
/// Command Palette's layout commands rely on ("snap left"/"move left"/
/// "left half"/"tile left"/"window left" all resolving to the same
/// `.leftHalf`), reusing `RuleBasedProvider.keywordLayouts` under the hood
/// (already covered by `RuleBasedProviderTests`) rather than a second
/// alias table.
final class CommandPaletteLayoutMatchTests: XCTestCase {

    func testAllFiveExampleAliasesResolveToTheSameLayout() {
        let phrasings = ["snap left", "move left", "left half", "tile left", "window left"]
        for phrase in phrasings {
            XCTAssertEqual(CommandPaletteState.matchedLayout(in: phrase), .leftHalf, "\"\(phrase)\" should match .leftHalf")
        }
    }

    func testBareKeywordMatchesWithNoVerbAtAll() {
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "left"), .leftHalf)
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "right"), .rightHalf)
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "maximize"), .maximize)
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "center"), .center)
    }

    func testAppNamePrefixedQueryStillMatches() {
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "safari left"), .leftHalf)
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "xcode top right"), .topRight)
    }

    func testCornerPhraseBeatsBareKeyword() {
        // "top left" must resolve to the corner, not the bare "top"/"left"
        // half entries the table also contains — relies on the shared
        // table's own longest-first ordering.
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "safari top left"), .topLeft)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(CommandPaletteState.matchedLayout(in: "SNAP LEFT"), .leftHalf)
    }

    func testNoMatchForUnrelatedText() {
        XCTAssertNil(CommandPaletteState.matchedLayout(in: "safari"))
        XCTAssertNil(CommandPaletteState.matchedLayout(in: "quit slack"))
        XCTAssertNil(CommandPaletteState.matchedLayout(in: ""))
    }
}
