import XCTest
@testable import JgDo

/// `AppSettings.hasCompletedOnboarding` is a plain `UserDefaults`-backed
/// flag, but it's the one piece of new state B1 introduces (the app had
/// zero first-run/onboarding concept before this), so it gets a
/// dedicated round-trip test rather than being assumed correct.
final class OnboardingStateTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettings.hasCompletedOnboardingKey)
        super.tearDown()
    }

    func testDefaultsToFalseOnFirstLaunch() {
        UserDefaults.standard.removeObject(forKey: AppSettings.hasCompletedOnboardingKey)
        XCTAssertFalse(AppSettings.hasCompletedOnboarding, "onboarding must show on a fresh install")
    }

    func testSettingTrueRoundTrips() {
        AppSettings.hasCompletedOnboarding = true
        XCTAssertTrue(AppSettings.hasCompletedOnboarding)
    }

    func testDoesNotResetOnceCompleted() {
        AppSettings.hasCompletedOnboarding = true
        // Re-reading must not implicitly reset it back to false — this is
        // the exact bug shape that would show onboarding on every launch.
        XCTAssertTrue(AppSettings.hasCompletedOnboarding)
        XCTAssertTrue(AppSettings.hasCompletedOnboarding)
    }

    func testWorkflowInsightsEnabledDefaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: WorkflowInsightsService.enabledKey)
        XCTAssertTrue(WorkflowInsightsService.shared.isEnabled, "opt-out, not opt-in, matching ClipboardService's convention")
        UserDefaults.standard.removeObject(forKey: WorkflowInsightsService.enabledKey)
    }

    func testWorkflowInsightsCanBeDisabled() {
        UserDefaults.standard.set(false, forKey: WorkflowInsightsService.enabledKey)
        XCTAssertFalse(WorkflowInsightsService.shared.isEnabled)
        UserDefaults.standard.removeObject(forKey: WorkflowInsightsService.enabledKey)
    }
}
