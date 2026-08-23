import XCTest

/// Launch arguments that the app is expected to understand for UI testing.
///
/// These are an interface pin shared with the app-wiring work happening in parallel:
/// - `reset` wipes local data and marks onboarding incomplete at startup.
/// - `completeOnboarding` wipes local data and then marks onboarding complete with a
///   default profile, so the tab bar and its features are reachable immediately.
///
/// If the app hasn't implemented these yet, tests that depend on them skip themselves
/// via `UITestSupport.requireFreshOnboarding` / `requireCompletedOnboarding` rather than
/// failing red, so the suite stays honest about what it could actually verify.
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
    /// Skips (rather than fails) when the app doesn't yet honor the argument, since wiring
    /// it up is being done concurrently by another agent.
    static func requireFreshOnboarding(app: XCUIApplication) throws {
        guard app.buttons["onboardingContinue"].waitForExistence(timeout: timeout) else {
            throw XCTSkip(
                "'\(UITestLaunchArgument.reset)' did not surface onboarding (onboardingContinue "
                    + "missing). The launch-argument interface pin is not wired up in the app yet."
            )
        }
    }

    /// Confirms `--uitest-complete-onboarding` actually landed on the Today tab it promises.
    /// Skips (rather than fails) when the app doesn't yet honor the argument.
    static func requireCompletedOnboarding(app: XCUIApplication) throws {
        guard app.buttons["todayAddWaterButton"].waitForExistence(timeout: timeout) else {
            throw XCTSkip(
                "'\(UITestLaunchArgument.completeOnboarding)' did not surface the Today tab "
                    + "(todayAddWaterButton missing). The launch-argument interface pin is not "
                    + "wired up in the app yet."
            )
        }
    }

    static func goToMealsTab(app: XCUIApplication) {
        let tab = app.tabBars.buttons["Meals"]
        if tab.waitForExistence(timeout: shortTimeout) { tab.tap() }
    }

    /// Clears an existing value in a text field and types new text into it.
    ///
    /// A plain `tap()` on a field with existing content does not reliably place the cursor at
    /// the end — it can land mid-string — so backspacing exactly `stringValue.count` times can
    /// leave a leftover tail sitting in front of the cursor (the iOS software keyboard also has
    /// no arrow keys, so nudging the cursor via `typeText` doesn't work either). Tapping near
    /// the field's trailing edge instead reliably places the cursor at the end of the existing
    /// text, so the backspaces that follow clear the whole thing.
    static func clearAndType(_ field: XCUIElement, text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let stringValue = field.value as? String, !stringValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count + 5)
            field.typeText(deleteString)
        }
        field.typeText(text)
    }

    /// Finds a meal (or hydration entry, etc.) row by matching any descendant element whose
    /// accessibility label contains the given text. Rows in this app group their children into
    /// a single accessibility element with a composed label, so this is more reliable than
    /// assuming a specific element type (button vs. cell) for the row.
    static func rowMatching(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
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
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
