import XCTest

/// Launch arguments that the app is expected to understand for UI testing.
///
/// These are an interface pin shared with the app-wiring work happening in parallel:
/// - `reset` wipes local data and marks onboarding incomplete at startup.
/// - `completeOnboarding` wipes local data and then marks onboarding complete with a
///   default profile, so the tab bar and its features are reachable immediately.
///
/// These arguments are part of the app's test contract. A missing destination is a test
/// failure: silently skipping would allow the suite to report green without exercising
/// the product flows it exists to verify.
enum UITestLaunchArgument {
    static let reset = "--uitest-reset"
    static let completeOnboarding = "--uitest-complete-onboarding"
}

enum UITestSupport {
    static let timeout: TimeInterval = 10
    static let shortTimeout: TimeInterval = 4

    /// Launches a fresh `XCUIApplication` instance with the given launch arguments.
    /// Every test should build its own app instance so tests stay independent of one another.
    @discardableResult
    static func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Confirms `--uitest-reset` actually produced the fresh onboarding screen it promises.
    static func requireFreshOnboarding(app: XCUIApplication) throws {
        guard app.buttons["onboardingContinue"].waitForExistence(timeout: timeout) else {
            throw UITestContractError.missingDestination(
                "'\(UITestLaunchArgument.reset)' did not surface onboarding (onboardingContinue "
                    + "missing)."
            )
        }
    }

    /// Confirms `--uitest-complete-onboarding` actually landed on the Today tab it promises.
    static func requireCompletedOnboarding(app: XCUIApplication) throws {
        guard app.buttons["todayAddWaterButton"].waitForExistence(timeout: timeout) else {
            throw UITestContractError.missingDestination(
                "'\(UITestLaunchArgument.completeOnboarding)' did not surface the Today tab "
                    + "(todayAddWaterButton missing)."
            )
        }
    }

    static func goToMealsTab(app: XCUIApplication) {
        let tab = app.tabBars.buttons["Meals"]
        if tab.waitForExistence(timeout: shortTimeout) { tab.tap() }
    }

    static func saveMealEditor(app: XCUIApplication) {
        let save = app.buttons["mealEditorSave"]
        XCTAssertTrue(save.isEnabled, "Expected a valid meal to be ready to save")
        save.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["mealEditorName"]
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: timeout), .completed,
            "Saving must finish and dismiss the editor before interacting with meal rows"
        )
    }

    /// Clears an existing value in a text field and types new text into it. Command-A is more
    /// reliable than synthesizing a long backspace sequence and also avoids treating placeholder
    /// text as editable content. A normal center tap is used because trailing-edge coordinate
    /// taps do not consistently grant keyboard focus on every supported simulator runtime.
    static func clearAndType(_ field: XCUIElement, text: String) {
        field.tap()
        let keyboard = XCUIApplication().keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: shortTimeout), "Expected text field to receive keyboard focus")
        if let stringValue = field.value as? String,
           !stringValue.isEmpty,
           stringValue != "Meal name" {
            field.typeKey("a", modifierFlags: .command)
        }
        field.typeText(text)
    }

    /// Finds the tappable row whose composed accessibility label contains the given text.
    /// Meal rows expose both their button and several matching descendants; returning the
    /// button avoids tapping a static-text child that cannot open the editor.
    static func rowMatching(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[cd] %@", text))
            .firstMatch
    }

    /// Taps an element that is visually tappable but that XCUITest reports as non-hittable.
    ///
    /// On iOS 26, horizontal `ScrollView`s carry full-size scroll-edge-effect layers
    /// (`AdditionalDimmingOverlay` etc.) as accessibility elements stacked above their
    /// content, so hit-testing a chip inside one resolves to the overlay and `tap()` fails
    /// even though a real finger tap works. A coordinate tap targets the element's frame
    /// directly and bypasses the hittability resolution.
    static func tapAllowingOverlay(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: shortTimeout), "Expected control to exist before tapping")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}

private enum UITestContractError: LocalizedError {
    case missingDestination(String)

    var errorDescription: String? {
        switch self {
        case .missingDestination(let message): message
        }
    }
}
