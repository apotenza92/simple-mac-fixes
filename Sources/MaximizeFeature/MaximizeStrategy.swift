import AppKit
import ApplicationServices
import Foundation

struct MaximizeResult: Equatable {
    let succeeded: Bool
    let appliedRect: CGRect?
    let restored: Bool
    let positionApplied: Bool
    let postApplyFrame: CGRect?
    let mutationExpectation: ManagedWindowMutationExpectation?
    let notes: [String]
}

protocol MaximizePerforming {
    func perform(on context: ClickedWindowContext) -> MaximizeResult
}

struct DragRestoreResult: Equatable {
    let restored: Bool
    let appliedRect: CGRect?
    let notes: [String]
    /// Where the pointer sits in the restored window, from its top left.
    var pointerOffset: CGPoint? = nil
}

struct RestoreFrameResolution: Equatable {
    let frame: CGRect
    let wasClamped: Bool
}

struct WindowFrameApplyResult: Equatable {
    let positionApplied: Bool
    let finalSizeError: AXError
    let postApplyFrame: CGRect?
    let notes: [String]
}

final class MaximizeStrategy: MaximizePerforming, @unchecked Sendable {
    private let frameStore: WindowFrameStore
    private let diagnostics: DebugDiagnostics
    private let screenProvider: () -> [ScreenDescriptor]

    private let frameSettleTimeout: TimeInterval = 0.35
    private let frameSettlePollInterval: TimeInterval = 0.05
    private let frameSettleStablePollCount = 2

    /// The length of the system's own fill animation. None under Reduce Motion.
    /// How long the system's own fill takes (`fillAnimationProgress`).
    static let systemFillDuration: TimeInterval = 0.33
    /// The system's own speed, so the motion matches its fill. Twice that speed was
    /// tried and put back at the user's request.
    private let animationDuration: TimeInterval = MaximizeStrategy.systemFillDuration
    private let dragAnimationQueue = DispatchQueue(label: "Macsimize.DragRestoreAnimation", qos: .userInteractive)
    private let dragEventGate = DragEventGate()
    private let dragPositionQueue = DispatchQueue(label: "Macsimize.DragRestorePosition", qos: .userInteractive)
    private let animates: () -> Bool
    private let gap: () -> CGFloat

    init(
        frameStore: WindowFrameStore,
        diagnostics: DebugDiagnostics,
        screenProvider: @escaping () -> [ScreenDescriptor] = ScreenHelpers.currentScreens,
        animates: @escaping () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        gap: @escaping () -> CGFloat = { 0 }
    ) {
        self.gap = gap
        self.frameStore = frameStore
        self.diagnostics = diagnostics
        self.screenProvider = screenProvider
        self.animates = animates
    }

    /// How far along the animation is after `time` seconds: the system's fill animation,
    /// at the system's speed. Measured on a window filled, put back and dragged out of a
    /// fill with the system's own commands: all three fit a spring with no overshoot
    /// at 28 rad/s within a few points at every sample, and are within a point of the
    /// end after 0.33 s.
    static func fillAnimationProgress(at time: TimeInterval, rate: Double = 28) -> Double {
        guard time > 0 else {
            return 0
        }
        return 1 - (1 + rate * time) * exp(-rate * time)
    }

    /// Steps a window toward `destination` along the system's fill animation. The app
    /// that owns the window redraws at each step, and some take tens of milliseconds
    /// for one, so the steps go by the clock: a slow app gets fewer steps and the same
    /// duration. The caller writes the final frame itself, so this stops short of it.
    static func animateFrame(
        from source: CGRect,
        to destination: CGRect,
        duration: TimeInterval,
        frameInterval: TimeInterval = 1.0 / 60.0,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        waitForFrame: (() -> Void)? = nil,
        apply: (CGRect) -> Void
    ) {
        guard duration > 0, frameInterval > 0, !framesNearlyEqual(source, destination) else {
            return
        }

        let start = now()
        var nextStep = start + frameInterval
        while true {
            let wait = nextStep - now()
            if let waitForFrame {
                // The display sets the pace of the steps.
                waitForFrame()
            } else if wait > 0 {
                sleep(wait)
            }
            let elapsed = now() - start
            guard elapsed < duration else {
                return
            }
            // The system's curve, run over `duration` instead of its own 0.33 s.
            let eased = fillAnimationProgress(at: elapsed * systemFillDuration / duration)
            apply(CGRect(
                x: (source.minX + (destination.minX - source.minX) * eased).rounded(),
                y: (source.minY + (destination.minY - source.minY) * eased).rounded(),
                width: (source.width + (destination.width - source.width) * eased).rounded(),
                height: (source.height + (destination.height - source.height) * eased).rounded()
            ))
            nextStep = max(nextStep + frameInterval, now())
        }
    }

    func perform(on context: ClickedWindowContext) -> MaximizeResult {
        guard let currentFrame = context.windowFrame else {
            return MaximizeResult(succeeded: false, appliedRect: nil, restored: false, positionApplied: false, postApplyFrame: nil, mutationExpectation: nil, notes: [AppStrings.maximizeWindowFrameUnavailable])
        }

        guard context.canSetSize else {
            return MaximizeResult(succeeded: false, appliedRect: nil, restored: false, positionApplied: false, postApplyFrame: currentFrame, mutationExpectation: nil, notes: [AppStrings.maximizeWindowSizeNotSettable])
        }

        let screens = screenProvider()
        guard let chosenScreen = ScreenHelpers.bestScreen(for: currentFrame, screens: screens) else {
            return MaximizeResult(succeeded: false, appliedRect: nil, restored: false, positionApplied: false, postApplyFrame: currentFrame, mutationExpectation: nil, notes: [AppStrings.maximizeTargetDisplayUnavailable])
        }

        let targetFrame = Self.maximizedFrame(on: chosenScreen, in: screens, gap: gap())
        let storedState = frameStore.storedState(for: context.windowIdentifier)
        let shouldRestore = Self.shouldRestore(currentFrame: currentFrame, targetFrame: targetFrame, storedState: storedState)
        let restoreResolution = shouldRestore
            ? storedState.flatMap { Self.resolvedRestoreFrame(currentFrame: currentFrame, storedState: $0, screens: screens) }
            : nil
        let destinationFrame = restoreResolution?.frame ?? targetFrame

        diagnostics.logMessage(
            "Deterministic maximize preparing for \(context.windowIdentifier): source=\(NSStringFromRect(currentFrame)) screen=\(chosenScreen.identifier) visibleFrame=\(NSStringFromRect(targetFrame)) destination=\(NSStringFromRect(destinationFrame)) restore=\(shouldRestore)"
        )

        let readFrame = {
            AXHelpers.cgRect(of: context.windowElement)
        }

        if context.canSetPosition, animates() {
            // One step for each frame of the display, with the size and the position
            // written at the same instant (see `writeFrame`). Filmed at 120 frames a
            // second: with steps at 60 a second, the position and the size written one
            // after the other, a put-back showed 1 or 2 frames with the window's edges
            // 16 to 75 points out of step, and edges that moved backward.
            let clock = DisplayClock()
            clock.start(displayAt: CGPoint(x: currentFrame.midX, y: currentFrame.midY))
            // With the app's enhanced interface on (an assistive app asked for it), many
            // apps animate or hold back each write. The final write below turns it off too.
            Self.withTemporarilyDisabledEnhancedUI(for: context.pid) {
                Self.animateFrame(
                    from: currentFrame,
                    to: destinationFrame,
                    duration: animationDuration,
                    waitForFrame: { clock.waitForNextFrame() }
                ) { frame in
                    clock.step { Self.writeFrame(frame, to: context.windowElement, positionQueue: dragPositionQueue) }
                }
            }
            clock.stop()
        }

        let applyResult = Self.applyManagedFrame(
            destinationFrame: destinationFrame,
            pid: context.pid,
            canSetPosition: context.canSetPosition,
            adjustSizeFirst: false,
            settleTimeout: frameSettleTimeout,
            settlePollInterval: frameSettlePollInterval,
            settleStablePollCount: frameSettleStablePollCount,
            applyPosition: { origin in
                AXHelpers.set(position: origin, on: context.windowElement)
            },
            applySize: { size in
                AXHelpers.set(size: size, on: context.windowElement)
            },
            readFrame: readFrame
        )

        var notes = applyResult.notes
        guard applyResult.finalSizeError == .success else {
            notes.append(AppStrings.maximizeSizeSetFailed(code: applyResult.finalSizeError.rawValue))
            diagnostics.logMessage("Deterministic maximize failed for \(context.windowIdentifier): \(notes.joined(separator: " "))")
            return MaximizeResult(
                succeeded: false,
                appliedRect: nil,
                restored: shouldRestore,
                positionApplied: applyResult.positionApplied,
                postApplyFrame: readFrame(),
                mutationExpectation: nil,
                notes: notes
            )
        }

        let postApplyFrame = applyResult.postApplyFrame
        if let postApplyFrame, !Self.framesNearlyEqual(postApplyFrame, destinationFrame) {
            notes.append(AppStrings.maximizePostApplyFrameDiffers)
        }

        if shouldRestore {
            frameStore.removeStoredFrame(for: context.windowIdentifier)
            notes.append(AppStrings.maximizeRestoredPreviousFrame)
            if restoreResolution?.wasClamped == true {
                notes.append(AppStrings.maximizeRestoreClampedToVisibleFrame)
            } else {
                notes.append(AppStrings.maximizeRestoreExactFrame)
            }
        } else {
            let effectiveMaximizedFrame = postApplyFrame ?? destinationFrame
            if !Self.framesNearlyEqual(currentFrame, effectiveMaximizedFrame) {
                frameStore.storeTransition(
                    originalFrame: currentFrame,
                    maximizedFrame: effectiveMaximizedFrame,
                    for: context.windowIdentifier
                )
            }
        }

        diagnostics.logMessage(
            "Deterministic maximize applied to \(context.windowIdentifier): source=\(NSStringFromRect(currentFrame)) screen=\(chosenScreen.identifier) visibleFrame=\(NSStringFromRect(targetFrame)) destination=\(NSStringFromRect(destinationFrame)) post=\(postApplyFrame.map { NSStringFromRect($0) } ?? "-") positionApplied=\(applyResult.positionApplied)"
        )
        return MaximizeResult(
            succeeded: true,
            appliedRect: destinationFrame,
            restored: shouldRestore,
            positionApplied: applyResult.positionApplied,
            postApplyFrame: postApplyFrame,
            mutationExpectation: ManagedWindowMutationExpectation(
                sourceFrame: currentFrame,
                destinationFrame: destinationFrame,
                observedFrame: postApplyFrame,
                restored: shouldRestore
            ),
            notes: notes
        )
    }

    // Position-first writes avoid Brave's visible intermediate grow when maximising on the same screen.
    static func applyManagedFrame(
        destinationFrame: CGRect,
        pid: pid_t,
        canSetPosition: Bool,
        adjustSizeFirst: Bool = false,
        settleTimeout: TimeInterval,
        settlePollInterval: TimeInterval,
        settleStablePollCount: Int,
        applyPosition: (CGPoint) -> AXError,
        applySize: (CGSize) -> AXError,
        readFrame: () -> CGRect?
    ) -> WindowFrameApplyResult {
        withTemporarilyDisabledEnhancedUI(for: pid) {
            var notes: [String] = []
            let initialSizeError = adjustSizeFirst ? applySize(destinationFrame.size) : .success

            var positionApplied = false
            if canSetPosition {
                let positionError = applyPosition(destinationFrame.origin)
                if positionError == .success {
                    positionApplied = true
                } else {
                    notes.append(AppStrings.maximizePositionSetFailed(code: positionError.rawValue))
                }
            } else {
                notes.append(AppStrings.maximizePositionNotSettable)
            }

            let finalSizeError = applySize(destinationFrame.size)
            let postApplyFrame = settledFrameAfterApply(
                destinationFrame: destinationFrame,
                initialFrame: readFrame(),
                settleTimeout: settleTimeout,
                pollInterval: settlePollInterval,
                stablePollCount: settleStablePollCount,
                readFrame: readFrame
            )

            if adjustSizeFirst && initialSizeError != .success && finalSizeError == .success {
                notes.append("Initial AXSize write failed before succeeding on the final write.")
            }

            return WindowFrameApplyResult(
                positionApplied: positionApplied,
                finalSizeError: finalSizeError,
                postApplyFrame: postApplyFrame,
                notes: notes
            )
        }
    }

    private static func withTemporarilyDisabledEnhancedUI<T>(for pid: pid_t, work: () -> T) -> T {
        let appElement = AXUIElementCreateApplication(pid)
        let enhancedUIAttribute = "AXEnhancedUserInterface"
        let wasEnhancedUIEnabled = AXHelpers.boolAttribute(enhancedUIAttribute, on: appElement) ?? false

        if wasEnhancedUIEnabled {
            _ = AXHelpers.set(boolAttribute: enhancedUIAttribute, value: false, on: appElement)
        }

        let result = work()

        if wasEnhancedUIEnabled {
            _ = AXHelpers.set(boolAttribute: enhancedUIAttribute, value: true, on: appElement)
        }

        return result
    }

    var hasMaximizedWindows: Bool { !frameStore.isEmpty }

    func hasMaximizedWindow(pid: pid_t, at bounds: CGRect) -> Bool {
        frameStore.hasMaximizedWindow(pid: pid, at: bounds)
    }

    func isCurrentlyManagedMaximized(_ context: ClickedWindowContext) -> Bool {
        guard let currentFrame = context.windowFrame,
              let storedState = frameStore.storedState(for: context.windowIdentifier),
              storedState.lastManagedMaximizeFrame != nil else {
            return false
        }

        let screens = screenProvider()
        guard let chosenScreen = ScreenHelpers.bestScreen(for: currentFrame, screens: screens) else {
            return false
        }

        let targetFrame = Self.maximizedFrame(on: chosenScreen, in: screens, gap: gap())
        return Self.shouldRestore(currentFrame: currentFrame, targetFrame: targetFrame, storedState: storedState)
    }

    /// The frame of a maximized window: the screen's usable area, less `gap` at every
    /// edge. A gap that leaves no room counts as none.
    static func maximizedFrame(on screen: ScreenDescriptor, in screens: [ScreenDescriptor], gap: CGFloat) -> CGRect {
        let full = ScreenHelpers.accessibilityRect(forVisibleFrame: screen.visibleFrame, in: screens)
        guard gap > 0, full.width > gap * 4, full.height > gap * 4 else {
            return full
        }
        return full.insetBy(dx: gap, dy: gap)
    }

    /// Set from a press on a maximized window's title bar until the drag restores the
    /// window or ends. Used on the event tap's thread only.
    private var holdsDrag = false

    /// Keeps a maximized window where it is while a press on its title bar starts to
    /// move, as the system does for a window it filled: that window stays for the
    /// first 34 points or so and then comes away under the pointer. The app that owns
    /// the window gets its pointer moves with no button until then (`DragEventGate`),
    /// so it does not drag the window. The pointer itself moves as usual.
    func beginDragHold(on context: ClickedWindowContext) -> Bool {
        endDragHold()
        guard animates(),
              context.canSetSize, context.canSetPosition,
              let currentFrame = context.windowFrame,
              let maximizeFrame = frameStore.storedState(for: context.windowIdentifier)?.lastManagedMaximizeFrame,
              Self.framesNearlyEqual(currentFrame, maximizeFrame),
              dragEventGate.begin() else {
            return false
        }
        holdsDrag = true
        return true
    }

    func endDragHold() {
        guard holdsDrag else {
            return
        }
        holdsDrag = false
        dragEventGate.end()
    }

    func performDragRestore(
        on context: ClickedWindowContext,
        cursorLocation: CGPoint
    ) -> DragRestoreResult {
        // The animation takes the gate over. Every other way out gives it back.
        let wasHeld = holdsDrag
        var animationOwnsGate = false
        defer {
            if animationOwnsGate {
                holdsDrag = false
            } else {
                endDragHold()
            }
        }
        guard let currentFrame = context.windowFrame else {
            return DragRestoreResult(restored: false, appliedRect: nil, notes: [AppStrings.maximizeWindowFrameUnavailable])
        }
        guard context.canSetSize, context.canSetPosition else {
            return DragRestoreResult(restored: false, appliedRect: nil, notes: [AppStrings.maximizeWindowSizeNotSettable])
        }
        guard let storedState = frameStore.storedState(for: context.windowIdentifier) else {
            return DragRestoreResult(restored: false, appliedRect: nil, notes: [AppStrings.titleBarDragRestoreSkipped])
        }

        guard let maximizeFrame = storedState.lastManagedMaximizeFrame,
              Self.framesNearlyEqual(currentFrame, maximizeFrame) else {
            return DragRestoreResult(restored: false, appliedRect: nil, notes: [AppStrings.titleBarDragRestoreSkipped])
        }

        // The window is placed for the pointer position it has followed so far: the
        // press, plus any distance the window already moved. Apps differ in how much of
        // the drag they applied by now, so `DragFollower` then holds the window to the
        // pointer for the rest of the drag.
        // The window server's own answer for the place: the app's can be old mid-drag.
        var liveFrame = AXHelpers.cgRect(of: context.windowElement) ?? currentFrame
        if let origin = DragFollower.origin(ofWindow: context.windowNumber, element: context.windowElement) {
            liveFrame.origin = origin
        }
        // A held window did not move, and comes away under the pointer where the
        // pointer is now, as a window filled by the system does.
        let followedLocation = wasHeld ? cursorLocation : CGPoint(
            x: context.clickLocation.x + liveFrame.minX - currentFrame.minX,
            y: context.clickLocation.y + liveFrame.minY - currentFrame.minY
        )
        let screens = screenProvider()
        guard let restoreResolution = Self.resolvedRestoreFrame(
            currentFrame: liveFrame,
            storedState: storedState,
            screens: screens,
            cursorLocation: followedLocation
        ) else {
            return DragRestoreResult(restored: false, appliedRect: nil, notes: [AppStrings.maximizeTargetDisplayUnavailable])
        }
        let restoreFrame = restoreResolution.frame

        let pointerOffset = CGPoint(
            x: followedLocation.x - restoreFrame.minX,
            y: followedLocation.y - restoreFrame.minY
        )

        // A held drag already owns the gate. Otherwise this takes it now.
        if animates(), wasHeld || dragEventGate.begin() {
            animationOwnsGate = true
            // The event tap waits for this call, so the animation runs on a queue of
            // its own.
            frameStore.removeStoredFrame(for: context.windowIdentifier)
            diagnostics.logMessage(AppStrings.titleBarDragRestoreTriggered)
            let generation = dragEventGate.generation
            dragAnimationQueue.async { [animationDuration, positionQueue = dragPositionQueue, gate = dragEventGate] in
                // A press on another maximized window starts the gate again and clears its
                // release: from then on this drag is over, and its window stays where the
                // pointer last put it, not following the new drag.
                var last: CGPoint?
                let isOver = { gate.generation != generation }
                let pointer: () -> CGPoint? = {
                    if isOver() { return last }
                    last = gate.released ?? CGEvent(source: nil)?.location
                    return last
                }
                // From here to the end of the drag this moves the window, not its app.
                if gate.released == nil, let location = pointer() {
                    DragEventGate.sendRelease(at: location)
                }
                let clock = DisplayClock()
                clock.start(displayAt: followedLocation)
                Self.withTemporarilyDisabledEnhancedUI(for: context.pid) {
                    Self.animateDragRestore(
                        from: liveFrame.size,
                        to: restoreFrame.size,
                        pointerOffset: pointerOffset,
                        duration: animationDuration,
                        waitForFrame: { clock.waitForNextFrame() },
                        pointerLocation: pointer,
                        // Only the events say when the drag ends. The device's button state
                        // reads up for the whole of a three-finger drag on a trackpad, and the
                        // window then stayed where it restored.
                        isReleased: { isOver() || gate.released != nil },
                        applyFrame: { frame in
                            clock.step { Self.writeFrame(frame, to: context.windowElement, positionQueue: positionQueue) }
                        },
                        applyPosition: { origin in
                            clock.step { _ = AXHelpers.set(position: origin, on: context.windowElement) }
                        }
                    )
                }
                clock.stop()
                gate.end(generation: generation)
            }
            // No pointer offset: nothing else has to hold the window to the pointer.
            return DragRestoreResult(
                restored: true,
                appliedRect: restoreFrame,
                notes: [AppStrings.maximizeRestoredPreviousFrame]
            )
        }

        // Size first: the step between the two writes is then the short one. With the
        // position first, the full-size window showed moved sideways for up to 27 ms.
        let sizeError = AXHelpers.set(size: restoreFrame.size, on: context.windowElement)
        let positionError = AXHelpers.set(position: restoreFrame.origin, on: context.windowElement)
        guard positionError == .success, sizeError == .success else {
            var notes: [String] = []
            if positionError != .success {
                notes.append(AppStrings.maximizePositionSetFailed(code: positionError.rawValue))
            }
            if sizeError != .success {
                notes.append(AppStrings.maximizeSizeSetFailed(code: sizeError.rawValue))
            }
            return DragRestoreResult(restored: false, appliedRect: nil, notes: notes)
        }

        frameStore.removeStoredFrame(for: context.windowIdentifier)
        diagnostics.logMessage(AppStrings.titleBarDragRestoreTriggered)
        var notes = [AppStrings.maximizeRestoredPreviousFrame]
        if restoreResolution.wasClamped {
            notes.append(AppStrings.maximizeRestoreClampedToVisibleFrame)
        } else {
            notes.append(AppStrings.maximizeRestoreExactFrame)
        }
        return DragRestoreResult(
            restored: true,
            appliedRect: restoreFrame,
            notes: notes,
            pointerOffset: pointerOffset
        )
    }

    /// Shrinks a window that is being dragged, evenly toward the pointer, and then
    /// keeps it under the pointer until the button comes up. At every step the pointer
    /// keeps its share of the title bar's width and its height in the window.
    ///
    /// The window's app does not move the window meanwhile: the caller ended the app's
    /// own drag (`DragEventGate.sendRelease`) and sends it the pointer's moves with no
    /// button. Filmed at up to 120 frames a second against the true pointer position, on
    /// a window filled and dragged away by the system the window was off the pointer by
    /// up to 4 points sideways and 8 in height. This way it is off by 3 to 16 points
    /// during the animation in 8 of 10 drags (one frame of 37 to 46 points in the other
    /// 2) and by 3 to 8 points for the rest of the drag.
    ///
    /// Ways that let the app move the window were filmed and dropped:
    /// - the app gets every move, with a size and a position write at each step: the
    ///   app puts the window where its own drag says for single frames, 80 to 170
    ///   points away.
    /// - the app gets one move at each step and none for 12 to 20 ms after: the same,
    ///   53 to 93 points, at 25 steps a second.
    /// - the app gets no move until the animation ends: one frame 60 to 100 points
    ///   off when it gets the first one, in every drag, also when timed to the display.
    /// - the app's drag is ended and started again after the animation with a press
    ///   sent to it: no jump when the app takes it, but in most drags it did not, and
    ///   the window stood still for 0.2 s.
    /// - one position write, then the size alone: the window shrinks from its bottom
    ///   right corner, not evenly.
    static func animateDragRestore(
        from source: CGSize,
        to destination: CGSize,
        pointerOffset: CGPoint,
        duration: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        waitForFrame: @escaping () -> Void,
        pointerLocation: () -> CGPoint?,
        isReleased: () -> Bool,
        applyFrame: (CGRect) -> Void,
        applyPosition: (CGPoint) -> Void
    ) {
        let share = destination.width > 0 ? pointerOffset.x / destination.width : 0.5
        func frame(_ size: CGSize, _ pointer: CGPoint) -> CGRect {
            CGRect(
                x: (pointer.x - share * size.width).rounded(),
                y: (pointer.y - pointerOffset.y).rounded(),
                width: size.width,
                height: size.height
            )
        }

        var lastPointer: CGPoint?
        animateFrame(
            from: CGRect(origin: .zero, size: source),
            to: CGRect(origin: .zero, size: destination),
            duration: duration,
            now: now,
            waitForFrame: waitForFrame,
            apply: { step in
                lastPointer = pointerLocation() ?? lastPointer
                if let lastPointer {
                    applyFrame(frame(step.size, lastPointer))
                }
            }
        )

        let endSize = CGSize(width: destination.width.rounded(), height: destination.height.rounded())
        waitForFrame()
        lastPointer = pointerLocation() ?? lastPointer
        if let lastPointer {
            applyFrame(frame(endSize, lastPointer))
        }

        // The rest of the drag: one position for each frame the pointer moved in.
        while !isReleased() {
            waitForFrame()
            if let pointer = pointerLocation(), pointer != lastPointer {
                lastPointer = pointer
                applyPosition(frame(endSize, pointer).origin)
            }
        }
        if let pointer = pointerLocation(), pointer != lastPointer {
            applyPosition(frame(endSize, pointer).origin)
        }
    }

    /// Writes a window's size and its position so that the app takes both up one
    /// directly after the other. Accessibility has no single write for both, and
    /// the window is drawn in between with one of them old. Both are sent at the same
    /// instant, from two threads. Sent one after the other, also 0.5 ms apart, the
    /// app often started to redraw between them, and the second showed a frame late:
    /// the window was up to 140 points off the pointer for single frames.
    ///
    /// Filmed on an Electron app (GitHub Desktop), 15 animations for each way: this way
    /// 8 were clean and 7 had one frame 6 to 51 points out of step. The position
    /// first, then the size: 3 were clean. The size first: worse again. Electron draws
    /// a new size up to a frame after a new position. The system's own fill, from inside
    /// the app, was clean in 6 of 6: it changes both in one call, which an app outside
    /// cannot do. On Mail, which takes about 15 ms to lay out each size, 12 animations
    /// each: this way 1 clean (frames 19 to 134 points out of step), the size first and
    /// then the position 0 clean (37 to 171 points).
    static func writeFrame(_ frame: CGRect, to window: AXUIElement, positionQueue: DispatchQueue) {
        let sent = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        positionQueue.async(group: done) {
            sent.signal()
            AXHelpers.set(position: frame.origin, on: window)
        }
        sent.wait()
        AXHelpers.set(size: frame.size, on: window)
        done.wait()
    }

    static func targetRect(for windowFrame: CGRect, screens: [ScreenDescriptor]) -> CGRect? {
        ScreenHelpers.maximizeRect(for: windowFrame, screens: screens)
    }

    static func shouldRestore(currentFrame: CGRect, targetFrame: CGRect, storedState: StoredWindowFrameState?) -> Bool {
        guard let storedState else {
            return false
        }

        if let lastAppliedMaximizeFrame = storedState.lastManagedMaximizeFrame {
            let nearMaximizedState = framesNearlyEqual(currentFrame, lastAppliedMaximizeFrame) ||
                framesNearlyEqual(currentFrame, targetFrame)
            return nearMaximizedState && !framesNearlyEqual(storedState.restoreFrame, currentFrame)
        }

        return framesNearlyEqual(currentFrame, targetFrame) && !framesNearlyEqual(storedState.restoreFrame, targetFrame)
    }

    /// The restored window goes under the pointer at the same share of its width as the
    /// pointer had in the maximized window. macOS does this for a filled window dragged
    /// away (measured: grabs at 8, 30, 70 and 95 % ended at 8.1, 30.0, 70.0 and 95.1 %).
    /// Keeping the window's left or right edge, so the item under the pointer stays, was
    /// tried and dropped for the system's way. `currentFrame` is the window's frame now,
    /// mid-drag, so its top is kept and the pointer stays at the same height in the
    /// title bar (macOS lets it fall about 35 points).
    static func dragRestoreFrame(currentFrame: CGRect, restoreFrame: CGRect, cursorLocation: CGPoint) -> CGRect {
        let share = currentFrame.width > 0
            ? min(max((cursorLocation.x - currentFrame.minX) / currentFrame.width, 0), 1)
            : 0.5
        return CGRect(
            x: (cursorLocation.x - share * restoreFrame.width).rounded(),
            y: currentFrame.minY.rounded(),
            width: restoreFrame.width.rounded(),
            height: restoreFrame.height.rounded()
        )
    }

    static func resolvedRestoreFrame(
        currentFrame: CGRect,
        storedState: StoredWindowFrameState,
        screens: [ScreenDescriptor],
        cursorLocation: CGPoint? = nil
    ) -> RestoreFrameResolution? {
        guard let restoreScreen = restoreScreen(
            currentFrame: currentFrame,
            storedState: storedState,
            screens: screens
        ) else {
            return nil
        }

        let proposedFrame: CGRect
        if let cursorLocation {
            proposedFrame = dragRestoreFrame(
                currentFrame: currentFrame,
                restoreFrame: storedState.restoreFrame,
                cursorLocation: cursorLocation
            )
        } else {
            proposedFrame = storedState.restoreFrame.integral
        }

        let visibleFrame = ScreenHelpers.accessibilityRect(forVisibleFrame: restoreScreen.visibleFrame, in: screens)
        let clampedFrame = clampedRestoreFrame(proposedFrame, within: visibleFrame)
        return RestoreFrameResolution(
            frame: clampedFrame,
            wasClamped: !framesNearlyEqual(proposedFrame, clampedFrame, tolerance: 1)
        )
    }

    static func clampedRestoreFrame(_ restoreFrame: CGRect, within visibleFrame: CGRect) -> CGRect {
        let clampedSize = CGSize(
            width: min(restoreFrame.width, visibleFrame.width),
            height: min(restoreFrame.height, visibleFrame.height)
        )
        let maxX = visibleFrame.maxX - clampedSize.width
        let maxY = visibleFrame.maxY - clampedSize.height
        let clampedOrigin = CGPoint(
            x: min(max(restoreFrame.minX, visibleFrame.minX), maxX),
            y: min(max(restoreFrame.minY, visibleFrame.minY), maxY)
        )
        return CGRect(origin: clampedOrigin, size: clampedSize).integral
    }

    private static func restoreScreen(
        currentFrame: CGRect,
        storedState: StoredWindowFrameState,
        screens: [ScreenDescriptor]
    ) -> ScreenDescriptor? {
        if let originalScreen = bestIntersectingScreen(for: storedState.restoreFrame, screens: screens) {
            return originalScreen
        }
        if let maximizeFrame = storedState.lastManagedMaximizeFrame,
           let maximizeScreen = ScreenHelpers.bestScreen(for: maximizeFrame, screens: screens) {
            return maximizeScreen
        }
        return ScreenHelpers.bestScreen(for: currentFrame, screens: screens)
    }

    private static func bestIntersectingScreen(for frame: CGRect, screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens
            .map { screen in
                (
                    screen: screen,
                    area: intersectionArea(
                        frame,
                        ScreenHelpers.accessibilityRect(forScreen: screen, in: screens)
                    )
                )
            }
            .filter { $0.area > 0 }
            .max { lhs, rhs in lhs.area < rhs.area }?
            .screen
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }

    static func framesNearlyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    static func settledFrameAfterApply(
        destinationFrame: CGRect,
        initialFrame: CGRect?,
        settleTimeout: TimeInterval,
        pollInterval: TimeInterval,
        stablePollCount: Int,
        readFrame: () -> CGRect?,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> CGRect? {
        guard var lastFrame = initialFrame ?? readFrame() else {
            return nil
        }

        if framesNearlyEqual(lastFrame, destinationFrame)
            || settleTimeout <= 0
            || pollInterval <= 0
            || stablePollCount <= 0 {
            return lastFrame
        }

        var unchangedPolls = 0
        let deadline = Date().addingTimeInterval(settleTimeout)

        while Date() < deadline {
            sleep(pollInterval)
            guard let nextFrame = readFrame() else {
                continue
            }

            if framesNearlyEqual(nextFrame, destinationFrame) {
                return nextFrame
            }

            if framesNearlyEqual(nextFrame, lastFrame) {
                unchangedPolls += 1
                if unchangedPolls >= stablePollCount {
                    return nextFrame
                }
            } else {
                lastFrame = nextFrame
                unchangedPolls = 0
            }
        }

        return lastFrame
    }
}
