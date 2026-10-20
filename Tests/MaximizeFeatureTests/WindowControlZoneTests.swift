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

    func testTheTopLeftCornerIsTheButtonsAndTheRestOfTheTopIsTheTitleBar() {
        XCTAssertEqual(WindowControlZone.region(at: CGPoint(x: 160, y: 214), windows: [window], displays: []), .windowButtons)
        XCTAssertEqual(WindowControlZone.region(at: CGPoint(x: 500, y: 214), windows: [window], displays: []), .titleBar)
        XCTAssertEqual(WindowControlZone.region(at: CGPoint(x: 150, y: 300), windows: [window], displays: []), .titleBar)
        XCTAssertNil(WindowControlZone.region(at: CGPoint(x: 150, y: 500), windows: [window], displays: []))
    }

    func testScreenCoveringOverlaysInFrontAreLookedPast() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        // The Dock's full-screen window, and an overlay bigger than the screen.
        let dock = WindowControlZone.Window(bounds: display, layer: 20, alpha: 1)
        let overlay = WindowControlZone.Window(bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440), layer: 0, alpha: 1)
        XCTAssertEqual(WindowControlZone.region(at: CGPoint(x: 160, y: 214), windows: [dock, overlay, window], displays: [display]),
                       .windowButtons)
    }
}

final class BoundedContextResolverTests: XCTestCase {
    private final class SlowResolver: GreenButtonContextResolving, TitleBarContextResolving, @unchecked Sendable {
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        func resolveGreenButtonClick(at location: CGPoint) -> ClickedWindowContext? {
            Thread.sleep(forTimeInterval: delay)
            return nil
        }
        func resolveTitleBarInteraction(at location: CGPoint, isDoubleClick: Bool) -> TitleBarInteractionContext? {
            Thread.sleep(forTimeInterval: delay)
            return nil
        }
    }

    func testASlowAppNeverHoldsAClickPastTheDeadline() {
        let resolver = BoundedContextResolver(base: SlowResolver(delay: 2), deadline: 0.1)
        let start = Date()
        XCTAssertNil(resolver.resolveGreenButtonClick(at: .zero))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        // Still busy with the first question: the next click doesn't wait at all.
        let next = Date()
        XCTAssertNil(resolver.resolveTitleBarInteraction(at: .zero, isDoubleClick: true))
        XCTAssertLessThan(Date().timeIntervalSince(next), 0.05)
    }
}

final class WindowFrameStoreSavingTests: XCTestCase {
    func testMaximizedWindowsAreRememberedAcrossRestarts() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WindowFrameStoreTests"))
        defaults.removePersistentDomain(forName: "WindowFrameStoreTests")
        let mine = "pid:\(getpid())-cgwindow:42"
        let gone = "pid:999999-cgwindow:7"
        let first = WindowFrameStore(defaults: defaults)
        first.storeTransition(originalFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
                              maximizedFrame: CGRect(x: 0, y: 30, width: 1440, height: 800), for: mine)
        first.storeTransition(originalFrame: .zero, maximizedFrame: .zero, for: gone)

        let again = WindowFrameStore(defaults: defaults)
        XCTAssertEqual(again.storedState(for: mine)?.restoreFrame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(again.storedState(for: mine)?.lastManagedMaximizeFrame, CGRect(x: 0, y: 30, width: 1440, height: 800))
        // Its app has quit.
        XCTAssertNil(again.storedState(for: gone))
        defaults.removePersistentDomain(forName: "WindowFrameStoreTests")
    }
}
