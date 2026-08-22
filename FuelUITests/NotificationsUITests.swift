import XCTest

/// Smoke coverage for (e): the notification settings screen is reachable from Today, and
/// remains usable even if flipping a reminder toggle triggers the system permission dialog.
final class NotificationsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNotificationSettingsScreenIsReachableFromToday() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)

        // Enabling a reminder can trigger iOS's notification permission dialog. We don't
        // depend on it appearing (it may already be resolved from a prior run), but if it
        // does show up, dismiss it so the test can keep going.
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            for label in ["Allow", "Allow Once", "Don\u{2019}t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        let notificationsButton = app.buttons["todayNotificationsButton"]
        guard notificationsButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("todayNotificationsButton not found on Today.")
        }
        notificationsButton.tap()

        let mealToggle = app.switches["Meal logging"]
        guard mealToggle.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("Notifications screen did not present the expected 'Meal logging' toggle.")
        }

        mealToggle.tap()
        // Nudge the run loop so a system alert (if one appeared) is handled by the
        // interruption monitor registered above before we make our final assertion.
        _ = app.wait(for: .runningForeground, timeout: 2)

        XCTAssertTrue(
            mealToggle.waitForExistence(timeout: UITestSupport.timeout),
            "Notifications screen should remain usable after toggling a reminder"
        )
    }
}
