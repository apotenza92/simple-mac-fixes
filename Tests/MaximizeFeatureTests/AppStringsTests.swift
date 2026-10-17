import XCTest
@testable import MaximizeFeature

final class AppStringsTests: XCTestCase {
    override func tearDown() {
        AppStrings.resetPreferredLanguagesProvider()
        AppStrings.resetCurrentVersionProvider()
        AppStrings.resetOperatingSystemVersionProvider()
        super.tearDown()
    }

    func testDefaultEnglishUsesMaximizeSpelling() {
        AppStrings.preferredLanguagesProvider = { ["en"] }

        XCTAssertEqual(AppStrings.maximizeModeTitle, "Maximize")
        XCTAssertEqual(AppStrings.maximizeAllMenuTitle, "Maximize All")
        XCTAssertEqual(AppStrings.behaviorSectionTitle, "Behavior")
        XCTAssertEqual(AppStrings.greenButtonBehaviorSectionTitle, "Green Button Behavior")
        XCTAssertEqual(
            AppStrings.maximizeModeHelp,
            "Option-click enters Full Screen."
        )
        XCTAssertEqual(
            AppStrings.fullScreenModeHelp,
            "Option-click Maximizes."
        )
    }

    func testBritishEnglishUsesMaximiseSpelling() {
        AppStrings.preferredLanguagesProvider = { ["en-GB"] }

        XCTAssertEqual(AppStrings.maximizeModeTitle, "Maximise")
        XCTAssertEqual(AppStrings.maximizeAllMenuTitle, "Maximise All")
        XCTAssertEqual(AppStrings.behaviorSectionTitle, "Behaviour")
        XCTAssertEqual(AppStrings.greenButtonBehaviorSectionTitle, "Green Button Behaviour")
        XCTAssertEqual(
            AppStrings.maximizeModeHelp,
            "Option-click enters Full Screen."
        )
        XCTAssertEqual(
            AppStrings.fullScreenModeHelp,
            "Option-click Maximises."
        )
    }

    func testAustralianEnglishUsesMaximiseSpelling() {
        AppStrings.preferredLanguagesProvider = { ["en-AU"] }

        XCTAssertEqual(AppStrings.maximizeModeTitle, "Maximise")
        XCTAssertEqual(AppStrings.maximizeAllMenuTitle, "Maximise All")
        XCTAssertEqual(AppStrings.behaviorSectionTitle, "Behaviour")
        XCTAssertEqual(AppStrings.greenButtonBehaviorSectionTitle, "Green Button Behaviour")
    }

    func testCurrentVersionStatusMessageUsesProvidedVersion() {
        AppStrings.currentVersionProvider = { "2.4.6" }

        XCTAssertEqual(AppStrings.currentVersionStatusMessage, "Current version: 2.4.6")
    }

    func testMacOS27DeviceControlWording() {
        AppStrings.operatingSystemVersionProvider = { OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0) }

        XCTAssertEqual(AppStrings.accessibilityButtonTitle, "Device Control and Data Access")
        XCTAssertTrue(AppStrings.permissionDetailAccessibilityRequired.contains("Device Control and Data Access"))
        XCTAssertFalse(AppStrings.permissionDetailAccessibilityRequired.contains(" > Accessibility"))
    }

    func testEarlierMacOSKeepsAccessibilityWording() {
        AppStrings.operatingSystemVersionProvider = { OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0) }

        XCTAssertEqual(AppStrings.accessibilityButtonTitle, "Accessibility")
        XCTAssertTrue(AppStrings.permissionDetailAccessibilityRequired.contains(" > Accessibility"))
    }
}
