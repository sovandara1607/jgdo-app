import XCTest
@testable import JgDo

/// `WorkspaceTemplate.builtIns` is static data — checks every template 
final class WorkspaceTemplateTests: XCTestCase {

    func testEveryTemplateHasAtLeastOneSlot() {
        for template in WorkspaceTemplate.builtIns {
            XCTAssertFalse(template.slots.isEmpty, template.name)
        }
    }

    func testEverySlotHasCandidateApps() {
        for template in WorkspaceTemplate.builtIns {
            for slot in template.slots {
                XCTAssertFalse(slot.candidateBundleIDs.isEmpty, "\(template.name) — \(slot.roleLabel)")
            }
        }
    }

    func testNonParkSlotsStayWithinTheScreenFraction() {
        for template in WorkspaceTemplate.builtIns {
            for slot in template.slots where !slot.park {
                let f = slot.fraction
                XCTAssertGreaterThanOrEqual(f.minX, 0, "\(template.name) — \(slot.roleLabel)")
                XCTAssertGreaterThanOrEqual(f.minY, 0, "\(template.name) — \(slot.roleLabel)")
                XCTAssertLessThanOrEqual(f.maxX, 1.001, "\(template.name) — \(slot.roleLabel)")
                XCTAssertLessThanOrEqual(f.maxY, 1.001, "\(template.name) — \(slot.roleLabel)")
                XCTAssertGreaterThan(f.width, 0, "\(template.name) — \(slot.roleLabel)")
                XCTAssertGreaterThan(f.height, 0, "\(template.name) — \(slot.roleLabel)")
            }
        }
    }

    func testTemplateIDsAreUnique() {
        let ids = WorkspaceTemplate.builtIns.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testMeetingHasAParkedSlot() {
        let meeting = WorkspaceTemplate.builtIns.first { $0.id == "meeting" }
        XCTAssertTrue(meeting?.slots.contains { $0.park } ?? false)
    }

    func testWritingFocusesOtherApps() {
        let writing = WorkspaceTemplate.builtIns.first { $0.id == "writing" }
        XCTAssertEqual(writing?.focusOthers, true)
    }

    func testOtherTemplatesDoNotFocusOthers() {
        for template in WorkspaceTemplate.builtIns where template.id != "writing" {
            XCTAssertFalse(template.focusOthers, template.name)
        }
    }
}
