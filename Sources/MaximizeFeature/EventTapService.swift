import AppKit
import ApplicationServices
import Foundation

final class EventTapService: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRunning = false
    @Published private(set) var lastFailureReason: String?

    private let diagnostics: DebugDiagnostics
    private let controller: GreenButtonInterceptionController
    private let titleBarController: TitleBarInterceptionController
    private let actionPerformer: WindowActionPerforming
    private let dragRestorePerformer: DragRestorePerforming

    private let callbackQueue = DispatchQueue(label: "Macsimize.EventTap.Callback")
    private let actionQueue = DispatchQueue(label: "Macsimize.EventTap.Action")
    private let stateQueue = DispatchQueue(label: "Macsimize.EventTap.State")

    private var configuration: InterceptionConfiguration
    private var bufferedEvents: [CGEvent] = []
    private var holdTimer: DispatchSourceTimer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Whether any window is still one this feature maximized, so dragging it could restore it.
    private let hasMaximizedWindows: () -> Bool
    private let interceptionTransactionStore = InterceptionTransactionStore()
    private let deferredReplayStore = DeferredReplayStore()
    private lazy var windowMutationMonitor = WindowMutationMonitor(diagnostics: diagnostics) { [weak self] event in
        self?.handleWindowMutation(event)
    }

    init(
        accessibilityService: AccessibilityService,
        actionEngine: WindowActionEngine,
        maximizeStrategy: MaximizeStrategy,
        diagnostics: DebugDiagnostics
    ) {
        self.diagnostics = diagnostics
        let resolver = BoundedContextResolver(base: accessibilityService)
        self.controller = GreenButtonInterceptionController(
            contextResolver: resolver,
            diagnostics: diagnostics
        )
        self.titleBarController = TitleBarInterceptionController(
            contextResolver: resolver,
            managedStateChecker: maximizeStrategy,
            diagnostics: diagnostics
        )
        self.actionPerformer = actionEngine
        self.dragRestorePerformer = maximizeStrategy
        self.hasMaximizedWindows = { maximizeStrategy.hasMaximizedWindows }
        self.configuration = InterceptionConfiguration(
            selectedAction: .maximize,
            diagnosticsEnabled: false
        )
    }

    func refreshConfiguration(
        selectedAction: WindowActionMode? = nil,
        diagnosticsEnabled: Bool? = nil
    ) {
        stateQueue.sync {
            configuration = InterceptionConfiguration(
                selectedAction: selectedAction ?? configuration.selectedAction,
                diagnosticsEnabled: diagnosticsEnabled ?? configuration.diagnosticsEnabled
            )
        }
    }

    func startIfPossible(
        selectedAction: WindowActionMode? = nil,
        diagnosticsEnabled: Bool? = nil
    ) {
        refreshConfiguration(
            selectedAction: selectedAction,
            diagnosticsEnabled: diagnosticsEnabled
        )
        let hadActiveTap = eventTap != nil || isRunning

        // Simple Mac Fixes owns permission prompts; only Accessibility is required here.
        guard AXIsProcessTrusted() else {
            if hadActiveTap {
                RuntimeLogger.log("startIfPossible: denied (no accessibility).")
            }
            stop(reason: "Accessibility permission has not been granted yet.")
            return
        }

        if SecureEventInput.isEnabled() {
            RuntimeLogger.log("startIfPossible: Secure Event Input is enabled; event interception may be limited.")
        }

        guard eventTap == nil else {
            updateRunningState(true, failure: nil)
            return
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            RuntimeLogger.log("Failed to start event tap.")
            updateRunningState(false, failure: AppStrings.eventTapUnavailableFailureReason)
            diagnostics.logMessage(AppStrings.eventTapCreationFailed, forceVisible: true)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        RuntimeLogger.log("Event tap started.")
        updateRunningState(true, failure: nil)
    }

    var hasEventTap: Bool { eventTap != nil }

    func restart() {
        stop(reason: nil)
        startIfPossible()
    }

    func stop(reason: String?) {
        let hadActiveTap = eventTap != nil || isRunning
        if let reason, hadActiveTap {
            RuntimeLogger.log("Stopping event tap: \(reason)")
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil

        callbackQueue.sync {
            cancelHoldTimer()
            bufferedEvents.removeAll()
            controller.reset()
            titleBarController.reset()
            interceptionTransactionStore.removeAll()
            deferredReplayStore.removeAll()
            windowMutationMonitor.removeAll()
        }

        updateRunningState(false, failure: reason)
    }

    private func updateRunningState(_ running: Bool, failure: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.isRunning != running || self.lastFailureReason != failure else {
                return
            }
            self.isRunning = running
            self.lastFailureReason = failure
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == WindowActionEngine.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            callbackQueue.sync {
                cancelHoldTimer()
                bufferedEvents.removeAll()
                controller.reset()
                titleBarController.reset()
                self.interceptionTransactionStore.removeAll()
                deferredReplayStore.removeAll()
                self.windowMutationMonitor.removeAll()
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            diagnostics.logMessage(AppStrings.eventTapReenabledMessage)
            return Unmanaged.passUnretained(event)
        }

        guard type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else {
            return Unmanaged.passUnretained(event)
        }

        return callbackQueue.sync {
            let config = stateQueue.sync { configuration }
            switch type {
            case .leftMouseDown:
                return processMouseDown(event, configuration: config)
            case .leftMouseDragged:
                return processMouseDragged(event)
            case .leftMouseUp:
                return processMouseUp(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }
    }

    private func processMouseDown(_ event: CGEvent, configuration: InterceptionConfiguration) -> Unmanaged<CGEvent>? {
        if shouldBypassInterception(for: event.location) {
            return Unmanaged.passUnretained(event)
        }
        // Asking the app about a click holds the click until it answers, so only ask
        // when the answer could matter: near the window buttons, on a title-bar
        // double-click, or to drag a maximized window back to its old size.
        let region = WindowControlZone.region(at: event.location, windows: WindowControlZone.onScreenWindows(),
                                              displays: WindowControlZone.displayBounds())
        let clickCount = event.getIntegerValueField(.mouseEventClickState)
        guard let region, region == .windowButtons || clickCount >= 2 || hasMaximizedWindows() else {
            controller.reset()
            titleBarController.reset()
            return Unmanaged.passUnretained(event)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let greenButtonDecision = region != .windowButtons ? .passThrough : controller.handleMouseDown(
            location: event.location,
            timestamp: timestamp,
            optionPressed: event.flags.contains(.maskAlternate),
            configuration: configuration
        )

        switch greenButtonDecision {
        case .passThrough:
            break
        case .consume(let context):
            if interceptionTransactionStore.hasActiveTransaction(for: .greenButton, key: context.interceptionKey) {
                diagnostics.logMessage(
                    "Suppressed green-button re-entry for \(context.windowIdentifier) while a maximize transaction is still active."
                )
                controller.reset()
                return nil
            }

            guard let copiedEvent = event.copy() else {
                return Unmanaged.passUnretained(event)
            }
            bufferedEvents = [copiedEvent]
            scheduleHoldTimer()
            return nil
        case .flushBufferedEvents:
            return Unmanaged.passUnretained(event)
        case .performAction:
            return Unmanaged.passUnretained(event)
        }

        let titleBarDecision = titleBarController.handleMouseDown(
            location: event.location,
            clickCount: clickCount,
            configuration: configuration
        )

        switch titleBarDecision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .performAction(let context):
            performTitleBarWindowActionAsync(context)
            return nil
        case .dragRestore:
            return Unmanaged.passUnretained(event)
        }
    }

    private func processMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !bufferedEvents.isEmpty else {
            switch titleBarController.handleMouseDragged(location: event.location) {
            case .dragRestore(let context, let cursorLocation):
                let result = dragRestorePerformer.performDragRestore(on: context, cursorLocation: cursorLocation)
                if result.restored {
                    clearManagedWindowTracking(
                        for: context.interceptionKey,
                        reason: "Cleared managed-window tracking for \(context.windowIdentifier) after drag-restore."
                    )
                } else {
                    diagnostics.logMessage(result.notes.first ?? AppStrings.titleBarDragRestoreSkipped)
                }
                return Unmanaged.passUnretained(event)
            case .passThrough, .consume, .performAction:
                return Unmanaged.passUnretained(event)
            }
        }

        if let copiedEvent = event.copy() {
            bufferedEvents.append(copiedEvent)
        }

        switch controller.handleMouseDragged(location: event.location) {
        case .consume(_):
            return nil
        case .flushBufferedEvents:
            flushBufferedEvents()
            return nil
        case .passThrough:
            cancelHoldTimer()
            bufferedEvents.removeAll()
            return Unmanaged.passUnretained(event)
        case .performAction:
            return nil
        }
    }

    private func processMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !bufferedEvents.isEmpty else {
            switch titleBarController.handleMouseUp() {
            case .consume:
                return nil
            case .passThrough, .dragRestore, .performAction:
                return Unmanaged.passUnretained(event)
            }
        }

        let decision = controller.handleMouseUp(
            location: event.location,
            timestamp: ProcessInfo.processInfo.systemUptime
        )

        switch decision {
        case .passThrough:
            cancelHoldTimer()
            bufferedEvents.removeAll()
            return Unmanaged.passUnretained(event)
        case .consume(_):
            return nil
        case .flushBufferedEvents:
            if let copiedEvent = event.copy() {
                bufferedEvents.append(copiedEvent)
            }
            flushBufferedEvents()
            return nil
        case .performAction(let pendingAction):
            cancelHoldTimer()
            var originalSequence = bufferedEvents
            if let copiedEvent = event.copy() {
                originalSequence.append(copiedEvent)
            }
            bufferedEvents.removeAll()
            let replaySequence = Self.replaySequence(for: pendingAction.mode, originalEvents: originalSequence)
            let replayToken = storeDeferredReplaySequence(replaySequence)
            performWindowActionAsync(pendingAction, replayToken: replayToken)
            return nil
        }
    }

    private func scheduleHoldTimer() {
        cancelHoldTimer()
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + 0.35)
        timer.setEventHandler { [weak self] in
            self?.processHoldTimeout()
        }
        holdTimer = timer
        timer.resume()
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func processHoldTimeout() {
        guard !bufferedEvents.isEmpty else {
            cancelHoldTimer()
            return
        }

        switch controller.handleHoldTimeout(timestamp: ProcessInfo.processInfo.systemUptime) {
        case .flushBufferedEvents:
            flushBufferedEvents()
        case .consume(_):
            break
        case .passThrough:
            cancelHoldTimer()
            bufferedEvents.removeAll()
        case .performAction:
            break
        }
    }

    private func flushBufferedEvents() {
        cancelHoldTimer()
        let eventsToReplay = bufferedEvents
        bufferedEvents.removeAll()
        replayOriginalMouseSequence(eventsToReplay)
    }

    private func performWindowActionAsync(_ pendingAction: PendingWindowAction, replayToken: UUID) {
        let mode = pendingAction.mode
        let context = pendingAction.context
        actionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let outcome = self.actionPerformer.perform(mode: mode, context: context)
            if outcome.handled {
                self.callbackQueue.async { [weak self] in
                    self?.clearDeferredReplaySequence(for: replayToken)
                    self?.recordHandledWindowAction(outcome: outcome, context: context)
                }
                return
            }

            switch outcome.failureDisposition {
            case .replayOriginalClick:
                self.callbackQueue.async { [weak self] in
                    self?.diagnostics.logMessage(AppStrings.eventTapReplayOriginalSequence)
                    self?.replayDeferredReplaySequence(for: replayToken)
                }
            case .dropInterceptedClick:
                self.callbackQueue.async { [weak self] in
                    self?.clearDeferredReplaySequence(for: replayToken)
                    self?.diagnostics.logMessage(AppStrings.eventTapSwallowNativeSequence)
                }
            }
        }
    }

    private func performTitleBarWindowActionAsync(_ context: ClickedWindowContext) {
        actionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let outcome = self.actionPerformer.perform(mode: .maximize, context: context)
            if outcome.handled {
                self.callbackQueue.async { [weak self] in
                    self?.clearManagedWindowTracking(
                        for: context.interceptionKey,
                        reason: "Cleared managed-window tracking for \(context.windowIdentifier) after a titlebar-managed window action."
                    )
                }
                return
            }
        }
    }

    private func replayOriginalMouseSequence(_ events: [CGEvent]) {
        for event in events {
            guard let copiedEvent = event.copy() else {
                continue
            }
            copiedEvent.setIntegerValueField(.eventSourceUserData, value: WindowActionEngine.syntheticEventMarker)
            copiedEvent.post(tap: .cghidEventTap)
        }
    }

    private func storeDeferredReplaySequence(_ events: [CGEvent]) -> UUID {
        deferredReplayStore.store(events)
    }

    private func replayDeferredReplaySequence(for token: UUID) {
        let events = deferredReplayStore.take(token) ?? []
        replayOriginalMouseSequence(events)
    }

    private func clearDeferredReplaySequence(for token: UUID) {
        deferredReplayStore.remove(token)
    }

    private func shouldBypassInterception(for location: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return false
        }
        return location.y > screen.visibleFrame.maxY
    }

    private func recordHandledWindowAction(outcome: WindowActionOutcome, context: ClickedWindowContext) {
        guard let interceptionKey = outcome.interceptionKey,
              let mutationExpectation = outcome.mutationExpectation else {
            return
        }

        guard Self.shouldTrackManagedWindowTransaction(for: mutationExpectation) else {
            diagnostics.logMessage(
                "Skipped green-button transaction tracking for \(context.windowIdentifier) because the managed frame was already settled at \(mutationExpectation.observedFrame.map { NSStringFromRect($0) } ?? "-")."
            )
            return
        }

        guard windowMutationMonitor.observeWindow(
            windowElement: context.windowElement,
            key: interceptionKey,
            mutationExpectation: mutationExpectation
        ) else {
            diagnostics.logMessage(
                "Window mutation monitor could not observe \(context.windowIdentifier); leaving green-button re-entry unmodified for this action."
            )
            return
        }

        interceptionTransactionStore.recordDispatched(
            for: .greenButton,
            key: interceptionKey,
            mutationExpectation: mutationExpectation
        )
        diagnostics.logMessage(
            "Tracking green-button transaction for \(context.windowIdentifier): source=\(NSStringFromRect(mutationExpectation.sourceFrame)) destination=\(NSStringFromRect(mutationExpectation.destinationFrame)) restored=\(mutationExpectation.restored)"
        )
    }

    private func handleWindowMutation(_ event: WindowMutationEvent) {
        callbackQueue.async { [weak self] in
            guard let self,
                  let transaction = self.interceptionTransactionStore.transaction(for: event.source, key: event.key),
                  let mutationExpectation = transaction.mutationExpectation else {
                return
            }

            guard Self.isSettledMutation(event.currentFrame, expectation: mutationExpectation) else {
                return
            }

            self.interceptionTransactionStore.markSettled(for: event.source, key: event.key)
            self.interceptionTransactionStore.removeTransaction(for: event.source, key: event.key)
            self.windowMutationMonitor.removeObservation(for: event.key)
            self.diagnostics.logMessage(
                "Settled \(event.source == .greenButton ? "green-button" : "titlebar") transaction for \(event.key.windowIdentifier) after \(event.notification): frame=\(NSStringFromRect(event.currentFrame))"
            )
        }
    }

    private func clearManagedWindowTracking(for key: WindowInterceptionKey, reason: String? = nil) {
        let removedGreenButtonTransaction = interceptionTransactionStore.removeTransaction(for: .greenButton, key: key)
        let removedTitleBarTransaction = interceptionTransactionStore.removeTransaction(for: .titleBar, key: key)
        let removedObservation = windowMutationMonitor.removeObservation(for: key)
        guard removedGreenButtonTransaction || removedTitleBarTransaction || removedObservation else {
            return
        }

        if let reason {
            diagnostics.logMessage(reason)
        }
    }

    private static func isSettledMutation(
        _ currentFrame: CGRect,
        expectation: ManagedWindowMutationExpectation
    ) -> Bool {
        MaximizeStrategy.framesNearlyEqual(currentFrame, expectation.destinationFrame)
    }

    static func shouldTrackManagedWindowTransaction(for expectation: ManagedWindowMutationExpectation) -> Bool {
        guard let observedFrame = expectation.observedFrame else {
            return true
        }
        return !MaximizeStrategy.framesNearlyEqual(observedFrame, expectation.destinationFrame)
    }

    static func replaySequence(for mode: WindowActionMode, originalEvents: [CGEvent]) -> [CGEvent] {
        guard mode == .fullScreen else {
            return originalEvents
        }

        return originalEvents.compactMap { event in
            guard let copiedEvent = event.copy() else {
                return nil
            }
            copiedEvent.flags.remove(.maskAlternate)
            return copiedEvent
        }
    }

    deinit {
        stop(reason: nil)
    }
}

extension WindowActionEngine: WindowActionPerforming {}
extension MaximizeStrategy: DragRestorePerforming {}

protocol WindowActionPerforming {
    func perform(mode: WindowActionMode, context: ClickedWindowContext) -> WindowActionOutcome
}

protocol DragRestorePerforming {
    func performDragRestore(on context: ClickedWindowContext, cursorLocation: CGPoint) -> DragRestoreResult
}

enum InterceptionSource: Hashable {
    case greenButton
    case titleBar
}

enum InterceptionTransactionPhase: Equatable {
    case dispatched
    case settled
}

struct InterceptionTransaction: Equatable {
    let source: InterceptionSource
    let key: WindowInterceptionKey
    let mutationExpectation: ManagedWindowMutationExpectation?
    let phase: InterceptionTransactionPhase
}

final class InterceptionTransactionStore {
    private var transactions: [InterceptionSource: [WindowInterceptionKey: InterceptionTransaction]] = [:]

    func recordDispatched(
        for source: InterceptionSource,
        key: WindowInterceptionKey,
        mutationExpectation: ManagedWindowMutationExpectation?
    ) {
        var transactionsForSource = transactions[source] ?? [:]
        transactionsForSource[key] = InterceptionTransaction(
            source: source,
            key: key,
            mutationExpectation: mutationExpectation,
            phase: .dispatched
        )
        transactions[source] = transactionsForSource
    }

    func transaction(for source: InterceptionSource, key: WindowInterceptionKey) -> InterceptionTransaction? {
        transactions[source]?[key]
    }

    func hasActiveTransaction(for source: InterceptionSource, key: WindowInterceptionKey) -> Bool {
        guard let transaction = transaction(for: source, key: key) else {
            return false
        }
        return transaction.phase != .settled
    }

    func markSettled(for source: InterceptionSource, key: WindowInterceptionKey) {
        guard var transactionsForSource = transactions[source],
              let transaction = transactionsForSource[key] else {
            return
        }

        transactionsForSource[key] = InterceptionTransaction(
            source: transaction.source,
            key: transaction.key,
            mutationExpectation: transaction.mutationExpectation,
            phase: .settled
        )
        transactions[source] = transactionsForSource
    }

    @discardableResult
    func removeTransaction(for source: InterceptionSource, key: WindowInterceptionKey) -> Bool {
        guard var transactionsForSource = transactions[source],
              transactionsForSource.removeValue(forKey: key) != nil else {
            return false
        }

        if transactionsForSource.isEmpty {
            transactions.removeValue(forKey: source)
        } else {
            transactions[source] = transactionsForSource
        }
        return true
    }

    func removeAll() {
        transactions.removeAll()
    }

    var isEmpty: Bool {
        transactions.isEmpty
    }
}

struct WindowMutationEvent {
    let source: InterceptionSource
    let key: WindowInterceptionKey
    let notification: String
    let currentFrame: CGRect
}

final class WindowMutationMonitor {
    private struct Observation {
        let key: WindowInterceptionKey
        let source: InterceptionSource
        let windowElement: AXUIElement
        let mutationExpectation: ManagedWindowMutationExpectation
    }

    private let diagnostics: DebugDiagnostics
    private let handler: (WindowMutationEvent) -> Void
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var observationsByKey: [WindowInterceptionKey: Observation] = [:]
    private var observedKeysByPID: [pid_t: Set<WindowInterceptionKey>] = [:]

    init(
        diagnostics: DebugDiagnostics,
        handler: @escaping (WindowMutationEvent) -> Void
    ) {
        self.diagnostics = diagnostics
        self.handler = handler
    }

    func observeWindow(
        windowElement: AXUIElement,
        key: WindowInterceptionKey,
        mutationExpectation: ManagedWindowMutationExpectation,
        source: InterceptionSource = .greenButton
    ) -> Bool {
        removeObservation(for: key)

        let pid = key.pid
        guard let observer = observer(for: pid) else {
            diagnostics.logMessage("AX observer unavailable for pid=\(pid) while tracking \(key.windowIdentifier).")
            return false
        }

        let notifications = [
            kAXMovedNotification as String,
            kAXResizedNotification as String,
            kAXUIElementDestroyedNotification as String
        ]

        var addedNotification = false
        for notification in notifications {
            let error = AXObserverAddNotification(
                observer,
                windowElement,
                notification as CFString,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            switch error {
            case .success, .notificationAlreadyRegistered:
                addedNotification = true
            case .notificationUnsupported:
                continue
            default:
                diagnostics.logMessage(
                    "AX observer add failed for pid=\(pid) window=\(key.windowIdentifier) notification=\(notification) code=\(error.rawValue)."
                )
            }
        }

        guard addedNotification else {
            return false
        }

        observationsByKey[key] = Observation(
            key: key,
            source: source,
            windowElement: windowElement,
            mutationExpectation: mutationExpectation
        )
        var observedKeys = observedKeysByPID[pid] ?? []
        observedKeys.insert(key)
        observedKeysByPID[pid] = observedKeys
        return true
    }

    @discardableResult
    func removeObservation(for key: WindowInterceptionKey) -> Bool {
        guard let observation = observationsByKey.removeValue(forKey: key) else {
            return false
        }


        if let observer = observersByPID[key.pid] {
            for notification in [
                kAXMovedNotification as String,
                kAXResizedNotification as String,
                kAXUIElementDestroyedNotification as String
            ] {
                _ = AXObserverRemoveNotification(observer, observation.windowElement, notification as CFString)
            }
        }

        if var observedKeys = observedKeysByPID[key.pid] {
            observedKeys.remove(key)
            if observedKeys.isEmpty {
                observedKeysByPID.removeValue(forKey: key.pid)
            } else {
                observedKeysByPID[key.pid] = observedKeys
            }
        }
        return true
    }

    func removeAll() {
        let keys = Array(observationsByKey.keys)
        keys.forEach { key in
            _ = removeObservation(for: key)
        }

        for observer in observersByPID.values {
            let source = AXObserverGetRunLoopSource(observer)
            removeRunLoopSource(source)
        }
        observersByPID.removeAll()
        observedKeysByPID.removeAll()
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let observer = observersByPID[pid] {
            return observer
        }

        var createdObserver: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else {
                return
            }
            let monitor = Unmanaged<WindowMutationMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleObserverNotification(element: element, notification: notification as String)
        }, &createdObserver)
        guard error == .success, let createdObserver else {
            diagnostics.logMessage("AX observer create failed for pid=\(pid) code=\(error.rawValue).")
            return nil
        }

        let source = AXObserverGetRunLoopSource(createdObserver)
        addRunLoopSource(source)
        observersByPID[pid] = createdObserver
        return createdObserver
    }

    private func handleObserverNotification(element: AXUIElement, notification: String) {
        guard let observation = observationsByKey.values.first(where: { observation in
            AXHelpers.elementsEqual(observation.windowElement, element)
        }) else {
            return
        }

        if notification == kAXUIElementDestroyedNotification as String {
            removeObservation(for: observation.key)
            return
        }

        guard let currentFrame = AXHelpers.cgRect(of: observation.windowElement) else {
            return
        }

        handler(
            WindowMutationEvent(
                source: observation.source,
                key: observation.key,
                notification: notification,
                currentFrame: currentFrame
            )
        )
    }

    private func addRunLoopSource(_ source: CFRunLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func removeRunLoopSource(_ source: CFRunLoopSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

final class InterceptionSuppressionStore {
    private var greenButtonSuppressionUntilByPID: [pid_t: TimeInterval] = [:]

    func shouldSuppress(
        for source: InterceptionSource,
        frontmostPID: pid_t?,
        now: TimeInterval
    ) -> Bool {
        pruneExpiredSuppressions(now: now)

        guard source == .greenButton,
              let frontmostPID,
              let suppressedUntil = greenButtonSuppressionUntilByPID[frontmostPID] else {
            return false
        }

        if now < suppressedUntil {
            return true
        }

        greenButtonSuppressionUntilByPID.removeValue(forKey: frontmostPID)
        return false
    }

    func recordGreenButtonSuppression(for pid: pid_t, now: TimeInterval, duration: TimeInterval) {
        greenButtonSuppressionUntilByPID[pid] = now + duration
    }

    func removeAll() {
        greenButtonSuppressionUntilByPID.removeAll()
    }

    var isEmpty: Bool {
        greenButtonSuppressionUntilByPID.isEmpty
    }

    private func pruneExpiredSuppressions(now: TimeInterval) {
        for (pid, deadline) in Array(greenButtonSuppressionUntilByPID) where deadline <= now {
            greenButtonSuppressionUntilByPID.removeValue(forKey: pid)
        }
    }
}

final class DeferredReplayStore {
    private var eventsByToken: [UUID: [CGEvent]] = [:]

    func store(_ events: [CGEvent]) -> UUID {
        let token = UUID()
        eventsByToken[token] = events
        return token
    }

    func take(_ token: UUID) -> [CGEvent]? {
        eventsByToken.removeValue(forKey: token)
    }

    func remove(_ token: UUID) {
        eventsByToken.removeValue(forKey: token)
    }

    func removeAll() {
        eventsByToken.removeAll()
    }

    var isEmpty: Bool {
        eventsByToken.isEmpty
    }
}
