import XCTest
@testable import MaximizeFeature

final class WindowFrameStoreTests: XCTestCase {
    func testStoreAndPopFrame() {
        let store = WindowFrameStore()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)

        store.store(frame: frame, for: "window-1")
        XCTAssertEqual(store.storedFrame(for: "window-1"), frame)
        XCTAssertEqual(store.popStoredFrame(for: "window-1"), frame)
        XCTAssertNil(store.storedFrame(for: "window-1"))
    }

    func testStoreTransitionTracksRestoreAndManagedMaximizeFrames() {
        let store = WindowFrameStore()
        let restoreFrame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let managedMaximizeFrame = CGRect(x: 0, y: 0, width: 1512, height: 900)

        store.storeTransition(originalFrame: restoreFrame, maximizedFrame: managedMaximizeFrame, for: "window-1")

        XCTAssertEqual(
            store.storedState(for: "window-1"),
            StoredWindowFrameState(restoreFrame: restoreFrame, lastManagedMaximizeFrame: managedMaximizeFrame)
        )
    }

    func testManagedStatesSnapshotOnlyIncludesManagedWindows() {
        let store = WindowFrameStore()
        store.store(frame: CGRect(x: 10, y: 20, width: 300, height: 400), for: "plain-window")
        store.storeTransition(
            originalFrame: CGRect(x: 50, y: 60, width: 700, height: 500),
            maximizedFrame: CGRect(x: 0, y: 0, width: 1512, height: 900),
            for: "managed-window"
        )

        XCTAssertEqual(Set(store.managedStatesSnapshot().keys), ["managed-window"])
        XCTAssertEqual(store.managedWindowIdentifiers(), ["managed-window"])
    }
}
