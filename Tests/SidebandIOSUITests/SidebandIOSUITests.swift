import XCTest

@MainActor final class SidebandIOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SIDEBAND_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["SIDEBAND_UI_TESTING"] = "1"
        app.launch()
    }

    func testCoreNavigationAndConversationCreation() throws {
        let settings = app.descendants(matching: .any)["app-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        retainScreenshot("01-home")

        app.descendants(matching: .any)["new-conversation"].tap()
        let address = app.textFields["new-conversation-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["create-conversation"].isEnabled)
        address.tap()
        address.typeText("0123456789abcdef0123456789abcdef")
        XCTAssertTrue(app.buttons["create-conversation"].isEnabled)
        retainScreenshot("02-new-conversation")
    }

    func testSettingsRemainReachableAndReadable() throws {
        let settings = app.descendants(matching: .any)["app-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings-row-connection"].waitForExistence(timeout: 8))
        retainScreenshot("03-settings")
    }

    func testNetworkConnectionsRemainDirectlyReachable() throws {
        let connections = app.descendants(matching: .any)["network-connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 15))
        connections.tap()
        XCTAssertTrue(app.descendants(matching: .any)["network-connections-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Network Status"].exists)
        retainScreenshot("04-network-connections")
    }

    func testBackgroundAndColdLaunchRecoveryKeepCoreControlsReachable() throws {
        XCTAssertTrue(app.descendants(matching: .any)["network-connections"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["new-conversation"].waitForExistence(timeout: 10))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["network-connections"].waitForExistence(timeout: 15))
        retainScreenshot("05-lifecycle-recovery")
    }

    private func retainScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
