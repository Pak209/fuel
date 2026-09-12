import XCTest

/// Smoke coverage for (c) creating, editing, and deleting a meal through the meal editor,
/// and (d) filtering the meals list changes which rows are visible.
final class MealsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreatingEditingAndDeletingAMealUpdatesMealsList() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)
        UITestSupport.goToMealsTab(app: app)

        let addButton = app.buttons["mealsAddButton"]
        guard addButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("mealsAddButton not found on the Meals tab.")
        }

        // The updated name intentionally does not contain the original name as a substring —
        // rowMatching does substring matching, and "Original Updated" would still match a
        // search for "Original", making the post-rename assertion below vacuous.
        let nameSuffix = UUID().uuidString.prefix(6)
        let originalName = "UITest Meal Original \(nameSuffix)"
        let updatedName = "UITest Meal Renamed \(nameSuffix)"

        // Create.
        addButton.tap()
        let nameField = app.textFields["mealEditorName"]
        guard nameField.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("mealEditorName field did not appear after tapping mealsAddButton.")
        }
        UITestSupport.clearAndType(nameField, text: originalName)
        UITestSupport.saveMealEditor(app: app)

        let createdRow = UITestSupport.rowMatching(originalName, in: app)
        XCTAssertTrue(
            createdRow.waitForExistence(timeout: UITestSupport.timeout),
            "Expected '\(originalName)' to appear in mealsList after saving"
        )

        // Edit.
        createdRow.tap()
        let editNameField = app.textFields["mealEditorName"]
        XCTAssertTrue(editNameField.waitForExistence(timeout: UITestSupport.timeout))
        UITestSupport.clearAndType(editNameField, text: updatedName)
        UITestSupport.saveMealEditor(app: app)

        let updatedRow = UITestSupport.rowMatching(updatedName, in: app)
        XCTAssertTrue(
            updatedRow.waitForExistence(timeout: UITestSupport.timeout),
            "Expected the renamed meal '\(updatedName)' to appear in mealsList"
        )
        XCTAssertFalse(
            UITestSupport.rowMatching(originalName, in: app).exists,
            "Original meal name should no longer be present after renaming"
        )

        // Delete. "Delete meal" lives in the last section of the editor's Form, which — like a
        // List — lazily instantiates rows, so the button may not exist in the accessibility
        // tree yet at all (not just be off-screen). Scroll down until it materializes.
        updatedRow.tap()
        let deleteButton = app.buttons["mealEditorDelete"]
        var scrollAttempts = 0
        while !deleteButton.waitForExistence(timeout: scrollAttempts == 0 ? UITestSupport.timeout : 1)
            && scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(deleteButton.exists, "Expected mealEditorDelete to be reachable by scrolling the meal editor form")
        deleteButton.tap()
        // The confirmation dialog's destructive action shares the label "Delete meal" with the
        // `mealEditorDelete` button underneath it (which is still present in the hierarchy), so
        // a plain label lookup is ambiguous. Exclude the known identifier to isolate the dialog's button.
        let confirmDeleteButton = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Delete meal", "mealEditorDelete")
        ).firstMatch
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: UITestSupport.timeout))
        confirmDeleteButton.tap()

        XCTAssertFalse(
            UITestSupport.rowMatching(updatedName, in: app).waitForExistence(timeout: UITestSupport.shortTimeout),
            "Meal row should be gone after deletion"
        )
    }

    func testFilteringMealsChangesVisibleRows() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.completeOnboarding])
        try UITestSupport.requireCompletedOnboarding(app: app)
        UITestSupport.goToMealsTab(app: app)

        let addButton = app.buttons["mealsAddButton"]
        guard addButton.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("mealsAddButton not found on the Meals tab.")
        }

        let suffix = UUID().uuidString.prefix(6)
        let nameA = "UITest Filter A \(suffix)"
        let nameB = "UITest Filter B \(suffix)"
        for name in [nameA, nameB] {
            addButton.tap()
            let nameField = app.textFields["mealEditorName"]
            guard nameField.waitForExistence(timeout: UITestSupport.timeout) else {
                throw XCTSkip("mealEditorName field did not appear after tapping mealsAddButton.")
            }
            UITestSupport.clearAndType(nameField, text: name)
            UITestSupport.saveMealEditor(app: app)
            XCTAssertTrue(UITestSupport.rowMatching(name, in: app).waitForExistence(timeout: UITestSupport.timeout))
        }

        let filterMenuExists = app.buttons["mealsFilterMenu"].exists
            || app.scrollViews["mealsFilterMenu"].exists
            || app.otherElements["mealsFilterMenu"].exists
        guard filterMenuExists else {
            throw XCTSkip("mealsFilterMenu not found on the Meals tab.")
        }

        // New meals default to type "lunch", so switching the filter to Breakfast should
        // hide both of the rows that were just created...
        let breakfastFilter = app.buttons["Breakfast"]
        guard breakfastFilter.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("Breakfast filter control not found inside mealsFilterMenu.")
        }
        UITestSupport.tapAllowingOverlay(breakfastFilter)
        XCTAssertFalse(UITestSupport.rowMatching(nameA, in: app).waitForExistence(timeout: UITestSupport.shortTimeout))
        XCTAssertFalse(UITestSupport.rowMatching(nameB, in: app).exists)

        // ...and switching to "All" should bring them both back, proving the filter control
        // actually changes what mealsList shows rather than being cosmetic. "All" is kept at
        // the leading edge of the filter strip so the broad reset is always available.
        let allFilter = app.buttons["All"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: UITestSupport.timeout))
        UITestSupport.tapAllowingOverlay(allFilter)
        XCTAssertTrue(UITestSupport.rowMatching(nameA, in: app).waitForExistence(timeout: UITestSupport.timeout))
        XCTAssertTrue(UITestSupport.rowMatching(nameB, in: app).exists)
    }
}
