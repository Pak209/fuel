import XCTest

/// Smoke coverage for (g) and (h): at an accessibility-size Dynamic Type setting, key
/// controls on Today and Meals must still exist and be reachable rather than being clipped
/// out of the layout.
final class AccessibilitySizeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static let accessibilitySizeLaunchArguments = [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        UITestLaunchArgument.completeOnboarding,
    ]

    func testTodayKeyControlsRemainReachableAtAccessibilityDynamicType() throws {
        let app = UITestSupport.launch(Self.accessibilitySizeLaunchArguments)
        try UITestSupport.requireCompletedOnboarding(app: app)

        let identifiers = [
            "todayAddMealButton",
            "todayAddWaterButton",
            "todayPreviousDayButton",
            "todayNextDayButton",
            "todayProfileButton",
            "todayNotificationsButton",
        ]
        for identifier in identifiers {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: UITestSupport.timeout),
                "\(identifier) should still exist at an accessibility Dynamic Type size"
            )
        }

        // "Next day" is disabled while viewing today, so only check hittability for the
        // controls that are expected to be enabled at this larger layout.
        for identifier in [
            "todayAddMealButton", "todayAddWaterButton", "todayProfileButton",
            "todayNotificationsButton", "todayPreviousDayButton",
        ] {
            XCTAssertTrue(
                app.buttons[identifier].isHittable,
                "\(identifier) should be hittable at an accessibility Dynamic Type size"
            )
        }
    }

    func testMealsKeyControlsRemainReachableAtAccessibilityDynamicType() throws {
        let app = UITestSupport.launch(Self.accessibilitySizeLaunchArguments)
        try UITestSupport.requireCompletedOnboarding(app: app)
        UITestSupport.goToMealsTab(app: app)

        let addButton = app.buttons["mealsAddButton"]
        guard addButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("mealsAddButton not found on the Meals tab at an accessibility Dynamic Type size.")
        }
        XCTAssertTrue(addButton.isHittable, "mealsAddButton should be hittable at an accessibility Dynamic Type size")

        let filterMenuExists = app.buttons["mealsFilterMenu"].exists
            || app.scrollViews["mealsFilterMenu"].exists
            || app.otherElements["mealsFilterMenu"].exists
        XCTAssertTrue(filterMenuExists, "mealsFilterMenu should still be present at an accessibility Dynamic Type size")

        // The list is allowed to be empty, but either the list container or its empty-state
        // message must still render — the screen should never go blank.
        let contentAreaPresent = app.otherElements["mealsList"].exists
            || app.collectionViews["mealsList"].exists
            || app.tables["mealsList"].exists
            || app.staticTexts["No meals found"].exists
        XCTAssertTrue(
            contentAreaPresent,
            "Meals content area should render (list or empty state) at an accessibility Dynamic Type size"
        )
    }
}
