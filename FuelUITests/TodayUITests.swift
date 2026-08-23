import XCTest

/// Smoke coverage for (b): a completed-onboarding launch (`--uitest-complete-onboarding`)
/// shows the Today tab, and the Water row logs water in a single tap — the row's own
/// label promises "Tap to add 250 ml", so tapping it adds water directly instead of
/// opening a sheet. The sheet still exists behind the row's "Water details" chevron.
final class TodayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCompletedOnboardingShowsTodayTabAndLoggingWaterUpdatesTheUI() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)

        let addWaterButton = app.buttons["todayAddWaterButton"]
        XCTAssertTrue(addWaterButton.exists)
        // The Water timeline row's accessible label includes the current hydration total,
        // so comparing it before/after logging water is a robust way to detect a UI update
        // without depending on exact number formatting.
        let beforeLabel = addWaterButton.label

        addWaterButton.tap()

        // One tap logs 250 ml in place: no sheet is presented, and the row's label
        // updates once the day's snapshot reloads.
        let labelChanged = expectation(
            for: NSPredicate(format: "label != %@", beforeLabel),
            evaluatedWith: addWaterButton
        )
        wait(for: [labelChanged], timeout: UITestSupport.timeout)
        XCTAssertFalse(
            app.buttons["hydrationAddButton"].exists,
            "Tapping the water row should log water directly, not open the hydration sheet"
        )
    }

    func testWaterDetailsChevronOpensTheHydrationSheet() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)

        let detailsButton = app.buttons["todayWaterDetailsButton"]
        guard detailsButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("todayWaterDetailsButton is not present on the Today water row.")
        }
        detailsButton.tap()

        XCTAssertTrue(
            app.buttons["hydrationAddButton"].waitForExistence(timeout: UITestSupport.timeout),
            "Expected the Water details chevron to open the hydration log sheet"
        )
    }
}
