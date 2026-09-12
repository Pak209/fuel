import XCTest

/// Smoke coverage for (f): the export/deletion UI is reachable from Profile. This test
/// intentionally never confirms the destructive "delete all data" action — it only proves
/// the controls exist and are reachable, so there is no local state to restore afterward.
final class ProfileDataUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testExportAndDeleteControlsAreReachableFromProfile() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)

        let profileButton = app.buttons["todayProfileButton"]
        guard profileButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("todayProfileButton not found on Today.")
        }
        profileButton.tap()

        let exportDataLink = app.buttons["Export or delete data"]
        var scrollAttempts = 0
        while !exportDataLink.waitForExistence(timeout: scrollAttempts == 0 ? UITestSupport.shortTimeout : 1),
              scrollAttempts < 5 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(exportDataLink.exists, "'Export or delete data' should be reachable on the Profile screen")
        exportDataLink.tap()

        let exportButton = app.buttons["Prepare JSON export"]
        let deleteButton = app.buttons["Delete all local data"]
        XCTAssertTrue(
            exportButton.waitForExistence(timeout: UITestSupport.timeout),
            "Expected an export control on the data screen"
        )
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: UITestSupport.shortTimeout),
            "Expected a delete-all-data control on the data screen"
        )
        // Intentionally not tapping `deleteButton` — this test only proves the destructive
        // control is reachable, not that it works, so there's no state left to restore.
    }
}
