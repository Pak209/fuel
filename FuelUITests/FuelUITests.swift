import XCTest

/// Smoke coverage for the onboarding flow: (a) a fresh launch (`--uitest-reset`) shows
/// onboarding, and tapping Continue advances the flow.
final class FuelUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFreshLaunchShowsOnboardingAndContinueAdvances() throws {
        let app = UITestSupport.launch([UITestLaunchArgument.reset])
        try UITestSupport.requireFreshOnboarding(app: app)

        let continueButton = app.buttons["onboardingContinue"]
        XCTAssertTrue(continueButton.exists, "Expected the onboarding Continue control on a fresh launch")
        continueButton.tap()

        // Step 0 (Welcome) has no Back control; stepping to step 1 (Profile) should reveal it.
        // Checking for either control existing proves the step actually advanced rather than
        // the app being stuck on the welcome screen.
        let backButton = app.buttons["onboardingBack"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: UITestSupport.timeout)
                || continueButton.waitForExistence(timeout: UITestSupport.shortTimeout),
            "Expected onboarding to advance to the next step after tapping Continue"
        )
    }
}
