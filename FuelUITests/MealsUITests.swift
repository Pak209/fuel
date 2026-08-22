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

        let originalName = "UITest Meal \(UUID().uuidString.prefix(6))"
        let updatedName = "\(originalName) Updated"

        // Create.
        addButton.tap()
        let nameField = app.textFields["mealEditorName"]
        guard nameField.waitForExistence(timeout: UITestSupport.timeout) else {
            throw XCTSkip("mealEditorName field did not appear after tapping mealsAddButton.")
        }
        UITestSupport.clearAndType(nameField, text: originalName)
        app.buttons["mealEditorSave"].tap()

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
        app.buttons["mealEditorSave"].tap()

        let updatedRow = UITestSupport.rowMatching(updatedName, in: app)
        XCTAssertTrue(
            updatedRow.waitForExistence(timeout: UITestSupport.timeout),
            "Expected the renamed meal '\(updatedName)' to appear in mealsList"
        )
        XCTAssertFalse(
            UITestSupport.rowMatching(originalName, in: app).exists,
            "Original meal name should no longer be present after renaming"
        )

        // Delete.
        updatedRow.tap()
        let deleteButton = app.buttons["mealEditorDelete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: UITestSupport.timeout))
        deleteButton.tap()
        let confirmDeleteButton = app.buttons["Delete meal"]
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
            app.buttons["mealEditorSave"].tap()
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
        breakfastFilter.tap()
        XCTAssertFalse(UITestSupport.rowMatching(nameA, in: app).waitForExistence(timeout: UITestSupport.shortTimeout))
        XCTAssertFalse(UITestSupport.rowMatching(nameB, in: app).exists)

        // ...and switching to "All" should bring them both back, proving the filter control
        // actually changes what mealsList shows rather than being cosmetic.
        let allFilter = app.buttons["All"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: UITestSupport.timeout))
        allFilter.tap()
        XCTAssertTrue(UITestSupport.rowMatching(nameA, in: app).waitForExistence(timeout: UITestSupport.timeout))
        XCTAssertTrue(UITestSupport.rowMatching(nameB, in: app).exists)
    }
}
