import XCTest
@testable import MaximizeFeature

final class WindowControlZoneTests: XCTestCase {
    private let window = WindowControlZone.Window(bounds: CGRect(x: 100, y: 200, width: 800, height: 600), layer: 0, alpha: 1)

    func testOnlyClicksNearAWindowsTopNeedAccessibility() {
        XCTAssertTrue(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 120, y: 212), windows: [window]))
        XCTAssertTrue(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 500, y: 310), windows: [window]))
        XCTAssertFalse(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 500, y: 500), windows: [window]))
        XCTAssertFalse(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 50, y: 50), windows: [window]))
    }

    func testTheFrontWindowUnderThePointerDecides() {
        let front = WindowControlZone.Window(bounds: CGRect(x: 100, y: 150, width: 300, height: 300), layer: 0, alpha: 1)
        // The click is near the back window's top but in the middle of the window in front.
        XCTAssertFalse(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 150, y: 290), windows: [front, window]))
    }

    func testMenusPopoversAndInvisibleWindowsAreSkipped() {
        let tileMenu = WindowControlZone.Window(bounds: CGRect(x: 110, y: 220, width: 240, height: 160), layer: 101, alpha: 1)
        XCTAssertFalse(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 150, y: 240), windows: [tileMenu, window]))
        let invisible = WindowControlZone.Window(bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), layer: 0, alpha: 0)
        XCTAssertTrue(WindowControlZone.mayContainWindowControls(at: CGPoint(x: 120, y: 212), windows: [invisible, window]))
    }
}
