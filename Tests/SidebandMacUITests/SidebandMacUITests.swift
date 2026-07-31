import XCTest
import AppKit

@MainActor final class SidebandMacUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SIDEBAND_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["SIDEBAND_UI_TESTING"] = "1"
        app.launch()
    }

    func testCoreNavigationAndConversationCreation() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        retainScreenshot("01-mac-home")

        app.typeKey("n", modifierFlags: .command)
        let address = app.textFields["new-conversation-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeText("0123456789abcdef0123456789abcdef")
        XCTAssertTrue(app.buttons["create-conversation"].isEnabled)
        retainScreenshot("02-mac-new-conversation")
    }

    func testSettingsSurviveWindowResize() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.matching(NSPredicate(format: "title CONTAINS[c] 'Settings'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let lowerRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let smallerLowerRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78))
        lowerRight.press(forDuration: 0.2, thenDragTo: smallerLowerRight)
        XCTAssertTrue(window.exists)
        retainScreenshot("03-mac-settings-resized")
    }

    func testNetworkConnectionsRemainDirectlyReachable() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let connections = app.descendants(matching: .any)["network-connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 8))
        connections.click()
        XCTAssertTrue(app.descendants(matching: .any)["network-connections-screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Network Status"].exists)
        retainScreenshot("04-mac-network-connections")
    }

    private func retainScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
