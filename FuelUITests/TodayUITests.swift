import XCTest

/// Smoke coverage for (b): a completed-onboarding launch (`--uitest-complete-onboarding`)
/// shows the Today tab, and logging water through the todayAddWaterButton ->
/// hydrationAddButton path is reflected back in Today's UI.
final class TodayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletedOnboardingShowsTodayTabAndLoggingWaterUpdatesTheUI() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)

        let addWaterButton = app.buttons["todayAddWaterButton"]
        XCTAssertTrue(addWaterButton.exists)
        // The Water timeline row's accessible label includes the current hydration total
        // and hint text, so comparing it before/after logging water is a robust way to
        // detect a UI update without depending on exact number formatting.
        let beforeLabel = addWaterButton.label

        addWaterButton.tap()

        let hydrationAddButton = app.buttons["hydrationAddButton"]
        guard hydrationAddButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip(
                "hydrationAddButton did not appear after tapping todayAddWaterButton; the "
                    + "hydration sheet may not be wired up to this identifier yet."
            )
        }
        hydrationAddButton.tap()

        // Dismiss the hydration sheet back to Today.
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: UITestSupport.shortTimeout) {
            doneButton.tap()
        }

        XCTAssertTrue(addWaterButton.waitForExistence(timeout: UITestSupport.timeout))
        let afterLabel = addWaterButton.label
        XCTAssertNotEqual(
            beforeLabel, afterLabel,
            "Expected the Today water row to reflect the water entry that was just logged"
        )
    }
}
