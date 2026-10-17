import ApplicationServices
import XCTest
@testable import MaximizeFeature

final class DeferredReplayStoreTests: XCTestCase {
    func testTakeReturnsStoredSequenceAndClearsToken() {
        let store = DeferredReplayStore()
        let token = store.store([])

        XCTAssertEqual(store.take(token)?.count, 0)
        XCTAssertNil(store.take(token))
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveClearsStoredSequenceWithoutReplaying() {
        let store = DeferredReplayStore()
        let token = store.store([])

        store.remove(token)

        XCTAssertNil(store.take(token))
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveAllClearsEveryStoredSequence() {
        let store = DeferredReplayStore()
        _ = store.store([])
        _ = store.store([])

        store.removeAll()

        XCTAssertTrue(store.isEmpty)
    }

    func testReplaySequenceForFullScreenRemovesAlternateModifier() {
        let event = makeMouseEvent()
        event.flags = [.maskAlternate, .maskCommand]

        let replaySequence = EventTapService.replaySequence(for: .fullScreen, originalEvents: [event])

        XCTAssertEqual(replaySequence.count, 1)
        XCTAssertFalse(replaySequence[0].flags.contains(.maskAlternate))
        XCTAssertTrue(replaySequence[0].flags.contains(.maskCommand))
    }

    func testReplaySequenceForMaximizeKeepsOriginalModifiers() {
        let event = makeMouseEvent()
        event.flags = [.maskAlternate, .maskCommand]

        let replaySequence = EventTapService.replaySequence(for: .maximize, originalEvents: [event])

        XCTAssertEqual(replaySequence.count, 1)
        XCTAssertTrue(replaySequence[0].flags.contains(.maskAlternate))
        XCTAssertTrue(replaySequence[0].flags.contains(.maskCommand))
    }

    func testGreenButtonSuppressionBlocksOnlyGreenButtonSource() {
        let store = InterceptionSuppressionStore()
        store.recordGreenButtonSuppression(for: 42, now: 10, duration: 0.6)

        XCTAssertTrue(store.shouldSuppress(for: .greenButton, frontmostPID: 42, now: 10.2))
        XCTAssertFalse(store.shouldSuppress(for: .titleBar, frontmostPID: 42, now: 10.2))
    }

    func testGreenButtonSuppressionDoesNotApplyToDifferentFrontmostApp() {
        let store = InterceptionSuppressionStore()
        store.recordGreenButtonSuppression(for: 42, now: 10, duration: 0.6)

        XCTAssertFalse(store.shouldSuppress(for: .greenButton, frontmostPID: 99, now: 10.2))
    }

    func testGreenButtonSuppressionExpiresAfterTimeout() {
        let store = InterceptionSuppressionStore()
        store.recordGreenButtonSuppression(for: 42, now: 10, duration: 0.6)

        XCTAssertFalse(store.shouldSuppress(for: .greenButton, frontmostPID: 42, now: 10.6))
        XCTAssertTrue(store.isEmpty)
    }

    func testTitleBarSourceNeverArmsSuppressionState() {
        let store = InterceptionSuppressionStore()

        XCTAssertFalse(store.shouldSuppress(for: .titleBar, frontmostPID: 42, now: 10))
        XCTAssertTrue(store.isEmpty)
    }

    func testInterceptionTransactionStoreRecordsPerWindowDispatchedState() {
        let store = InterceptionTransactionStore()
        let key = WindowInterceptionKey(pid: 42, windowIdentifier: "window-a", windowNumber: 1)
        let expectation = ManagedWindowMutationExpectation(
            sourceFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            destinationFrame: CGRect(x: 0, y: 30, width: 1440, height: 840),
            observedFrame: nil,
            restored: false
        )

        store.recordDispatched(for: .greenButton, key: key, mutationExpectation: expectation)

        XCTAssertEqual(
            store.transaction(for: .greenButton, key: key),
            InterceptionTransaction(
                source: .greenButton,
                key: key,
                mutationExpectation: expectation,
                phase: .dispatched
            )
        )
        XCTAssertTrue(store.hasActiveTransaction(for: .greenButton, key: key))
    }

    func testInterceptionTransactionStoreDoesNotTreatDifferentWindowInSamePIDAsActive() {
        let store = InterceptionTransactionStore()
        let firstKey = WindowInterceptionKey(pid: 42, windowIdentifier: "window-a", windowNumber: 1)
        let secondKey = WindowInterceptionKey(pid: 42, windowIdentifier: "window-b", windowNumber: 2)

        store.recordDispatched(for: .greenButton, key: firstKey, mutationExpectation: nil)

        XCTAssertFalse(store.hasActiveTransaction(for: .greenButton, key: secondKey))
    }

    func testInterceptionTransactionStoreMarkSettledRetainsTransactionButClearsActiveState() {
        let store = InterceptionTransactionStore()
        let key = WindowInterceptionKey(pid: 42, windowIdentifier: "window-a", windowNumber: 1)

        store.recordDispatched(for: .greenButton, key: key, mutationExpectation: nil)
        store.markSettled(for: .greenButton, key: key)

        XCTAssertEqual(store.transaction(for: .greenButton, key: key)?.phase, .settled)
        XCTAssertFalse(store.hasActiveTransaction(for: .greenButton, key: key))
    }

    func testInterceptionTransactionStoreRemoveTransactionClearsMatchingKeyOnly() {
        let store = InterceptionTransactionStore()
        let firstKey = WindowInterceptionKey(pid: 42, windowIdentifier: "window-a", windowNumber: 1)
        let secondKey = WindowInterceptionKey(pid: 42, windowIdentifier: "window-b", windowNumber: 2)

        store.recordDispatched(for: .greenButton, key: firstKey, mutationExpectation: nil)
        store.recordDispatched(for: .greenButton, key: secondKey, mutationExpectation: nil)
        store.removeTransaction(for: .greenButton, key: firstKey)

        XCTAssertNil(store.transaction(for: .greenButton, key: firstKey))
        XCTAssertNotNil(store.transaction(for: .greenButton, key: secondKey))
    }

    func testShouldTrackManagedWindowTransactionReturnsFalseWhenObservedFrameAlreadyMatchesDestination() {
        let expectation = ManagedWindowMutationExpectation(
            sourceFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            destinationFrame: CGRect(x: 0, y: 30, width: 1440, height: 840),
            observedFrame: CGRect(x: 0, y: 30, width: 1440, height: 840),
            restored: false
        )

        XCTAssertFalse(EventTapService.shouldTrackManagedWindowTransaction(for: expectation))
    }

    func testShouldTrackManagedWindowTransactionReturnsTrueWhenObservedFrameIsMissing() {
        let expectation = ManagedWindowMutationExpectation(
            sourceFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            destinationFrame: CGRect(x: 0, y: 30, width: 1440, height: 840),
            observedFrame: nil,
            restored: false
        )

        XCTAssertTrue(EventTapService.shouldTrackManagedWindowTransaction(for: expectation))
    }

    func testShouldTrackManagedWindowTransactionReturnsTrueWhenObservedFrameStillDiffers() {
        let expectation = ManagedWindowMutationExpectation(
            sourceFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            destinationFrame: CGRect(x: 0, y: 30, width: 1440, height: 840),
            observedFrame: CGRect(x: 12, y: 45, width: 1410, height: 820),
            restored: false
        )

        XCTAssertTrue(EventTapService.shouldTrackManagedWindowTransaction(for: expectation))
    }

    private func makeMouseEvent() -> CGEvent {
        let source = CGEventSource(stateID: .hidSystemState)!
        return CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
    }
}
