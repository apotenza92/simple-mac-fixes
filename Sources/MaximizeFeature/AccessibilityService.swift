import AppKit
import ApplicationServices
import Foundation

struct WindowCandidate {
    let axWindow: AXUIElement
    let cgWindowID: CGWindowID?
    let bounds: CGRect?
    let layer: Int?
    let alpha: Double?
    let isOnScreen: Bool
    let subrole: String?
    let spaceIDs: Set<Int>
    let isMinimized: Bool
}

struct CurrentSpaceWindowScan {
    let contexts: [ClickedWindowContext]
    let enumeratedAppCount: Int
    let candidateCount: Int
    let cgEntryCount: Int
    let activeSpaceCount: Int
    let resolvedWindowIDCount: Int
    let spaceResolvedCandidateCount: Int
}

final class AccessibilityService: @unchecked Sendable {
    private struct TitleBarInteractionRects {
        let draggableRect: CGRect
        let activationRect: CGRect
    }

    struct TitleBarHitAncestor {
        let role: String?
        let actions: [String]
        let frame: CGRect?
    }

    private enum TitleBarHitTestResolution {
        case resolved(TitleBarInteractionContext)
        case blocked
        case miss
    }

    private let diagnostics: DebugDiagnostics
    private let supportedGreenButtonSubroles: Set<String> = ["AXZoomButton", "AXFullScreenButton"]
    private let titleBarSupplementaryRoles: Set<String> = [kAXToolbarRole as String, kAXGroupRole as String, "AXTabGroup"]
    private let greenButtonHitTolerance: CGFloat = 8
    private let trafficLightHotZoneWidth: CGFloat = 180
    private let trafficLightHotZoneHeight: CGFloat = 64
    private let trafficLightHotZoneInset: CGFloat = 10
    private let fallbackTitleBarHeight: CGFloat = 56
    private let maxAncestorTraversalDepth = 10
    private let minimumCandidateWindowSize = CGSize(width: 40, height: 40)

    init(diagnostics: DebugDiagnostics) {
        self.diagnostics = diagnostics
    }

    func resolveGreenButtonClick(at location: CGPoint) -> ClickedWindowContext? {
        if isLikelyInMenuBar(location) {
            return nil
        }

        let candidatePoints = candidateHitTestPoints(for: location)
        let systemWideElement = AXUIElementCreateSystemWide()
        for candidatePoint in candidatePoints {
            var hitElement: AXUIElement?
            let hitError = AXUIElementCopyElementAtPosition(systemWideElement, Float(candidatePoint.x), Float(candidatePoint.y), &hitElement)
            guard hitError == .success, let hitElement else {
                continue
            }

            guard let buttonElement = resolveGreenButton(from: hitElement, clickLocation: candidatePoint),
                  let app = runningApplication(for: buttonElement) ?? runningApplication(for: hitElement) else {
                continue
            }
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                diagnostics.logMessage("AX hit-test skipped for Macsimize itself.")
                return nil
            }

            if candidatePoint != location {
                diagnostics.logMessage("AX hit-test succeeded using flipped screen coordinates.")
            }
            return context(for: buttonElement, app: app, clickLocation: location)
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            diagnostics.logMessage("AX hit-test skipped: no frontmost app.")
            return nil
        }

        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            diagnostics.logMessage("AX hit-test skipped for Macsimize itself.")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for candidatePoint in candidatePoints {
            if let resolved = resolveUsingFocusedWindowButtonLookup(
                app: app,
                appElement: appElement,
                candidatePoint: candidatePoint,
                originalLocation: location
            ) {
                if candidatePoint != location {
                    diagnostics.logMessage("AX window-button lookup succeeded using flipped screen coordinates.")
                } else {
                    diagnostics.logMessage("AX window-button lookup succeeded after hit-test fallback.")
                }
                return resolved
            }
        }

        diagnostics.logMessage("AX hit-test failed for pid=\(app.processIdentifier) at \(NSStringFromPoint(location)).")
        return nil
    }

    func resolveTitleBarInteraction(at location: CGPoint) -> TitleBarInteractionContext? {
        if isLikelyInMenuBar(location) {
            return nil
        }

        switch resolveTitleBarInteractionUsingHitTest(at: location) {
        case .resolved(let context):
            return context
        case .blocked:
            return nil
        case .miss:
            break
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            diagnostics.logMessage(AppStrings.titleBarDoubleClickIgnored)
            return nil
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in focusedOrMainWindows(in: appElement) {
            guard let windowFrame = AXHelpers.cgRect(of: window),
                  hasReliableFallbackTitleBarEvidence(in: window, windowFrame: windowFrame, preferredLocation: location),
                  let interactionRects = titleBarInteractionRects(for: window),
                  Self.shouldAcceptFallbackTitleBarInteraction(
                    originalLocation: location,
                    windowFrame: windowFrame,
                    draggableRect: interactionRects.draggableRect,
                    hasReliableFallbackEvidence: true
                  ) else {
                continue
            }
            guard let context = windowContext(
                for: window,
                app: app,
                clickLocation: location,
                sourceElement: window,
                role: kAXWindowRole as String,
                subrole: AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: window),
                actions: AXHelpers.actions(for: window)
            ) else {
                continue
            }
            diagnostics.logMessage(
                "Resolved titlebar interaction via fallback titlebar evidence for pid=\(app.processIdentifier) at \(NSStringFromPoint(location))."
            )
            return TitleBarInteractionContext(
                draggableRect: interactionRects.draggableRect,
                activationRect: interactionRects.activationRect,
                allowsActivationOutsideDraggableRect: false,
                windowContext: context
            )
        }

        return nil
    }

    func eligibleCurrentSpaceWindowsForMaximize() -> [ClickedWindowContext] {
        scanCurrentSpaceWindowsForMaximize().contexts
    }

    @discardableResult
    func enumerateCurrentSpaceWindowsForMaximize(
        matchingIdentifiers: Set<String>? = nil,
        onEligibleWindow: ((ClickedWindowContext) -> Void)? = nil
    ) -> CurrentSpaceWindowScan {
        let allCGEntries = Self.cgWindowEntries()
        var cachedSpaceIDsByWindowID: [CGWindowID: Set<Int>] = [:]

        func cachedSpaces(for windowID: CGWindowID) -> Set<Int> {
            if let cached = cachedSpaceIDsByWindowID[windowID] {
                return cached
            }
            let spaces = WindowSpacePrivateApis.spaces(for: windowID)
            cachedSpaceIDsByWindowID[windowID] = spaces
            return spaces
        }

        let activeSpaceIDs = Self.currentActiveSpaceIDs(entries: allCGEntries, spacesProvider: cachedSpaces)
        let currentSpaceEntries = Self.currentSpaceCGEntries(
            entries: allCGEntries,
            activeSpaceIDs: activeSpaceIDs,
            spacesProvider: cachedSpaces
        )
        let cgEntriesByPID = Dictionary(grouping: currentSpaceEntries) { entry in
            (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        }

        var contexts: [ClickedWindowContext] = []
        var enumeratedAppCount = 0
        var candidateCount = 0
        var resolvedWindowIDCount = 0
        var spaceResolvedCandidateCount = 0

        for processIdentifier in cgEntriesByPID.keys.sorted()
        where processIdentifier != 0 {
            guard let app = NSRunningApplication(processIdentifier: processIdentifier),
                  shouldEnumerateWindows(for: app) else {
                continue
            }
            enumeratedAppCount += 1

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let candidates = windowCandidates(
                windows: rawAppWindows(in: appElement),
                cgEntries: cgEntriesByPID[app.processIdentifier] ?? [],
                spacesProvider: cachedSpaces
            )

            candidateCount += candidates.count
            resolvedWindowIDCount += candidates.reduce(into: 0) { count, candidate in
                if candidate.cgWindowID != nil {
                    count += 1
                }
            }
            spaceResolvedCandidateCount += candidates.reduce(into: 0) { count, candidate in
                if !candidate.spaceIDs.isEmpty {
                    count += 1
                }
            }

            for candidate in candidates {
                guard Self.shouldIncludeCurrentSpaceStandardCandidate(candidate, activeSpaceIDs: activeSpaceIDs) else {
                    continue
                }

                guard let context = batchWindowContext(for: candidate, app: app) else {
                    continue
                }
                guard context.isResizable, context.canSetSize, context.windowFrame != nil else {
                    continue
                }
                if !Self.matchesRequestedIdentifier(context.windowIdentifier, matchingIdentifiers: matchingIdentifiers) {
                    continue
                }
                contexts.append(context)
                onEligibleWindow?(context)
            }
        }

        return CurrentSpaceWindowScan(
            contexts: contexts,
            enumeratedAppCount: enumeratedAppCount,
            candidateCount: candidateCount,
            cgEntryCount: allCGEntries.count,
            activeSpaceCount: activeSpaceIDs.count,
            resolvedWindowIDCount: resolvedWindowIDCount,
            spaceResolvedCandidateCount: spaceResolvedCandidateCount
        )
    }

    func scanCurrentSpaceWindowsForMaximize(matchingIdentifiers: Set<String>? = nil) -> CurrentSpaceWindowScan {
        enumerateCurrentSpaceWindowsForMaximize(matchingIdentifiers: matchingIdentifiers)
    }

    func captureFrontmostWindowSnapshot() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            diagnostics.logMessage(AppStrings.diagnosticsSnapshotSkippedNoFrontmostApp, forceVisible: true)
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = AXHelpers.elementAttribute(kAXFocusedWindowAttribute as String, on: appElement)
            ?? AXHelpers.elementAttribute(kAXMainWindowAttribute as String, on: appElement)

        guard let window = focusedWindow else {
            diagnostics.logMessage(
                AppStrings.diagnosticsSnapshotNoFocusedWindow(appName: app.localizedName ?? AppStrings.unknownLabel),
                forceVisible: true
            )
            return
        }

        let title = AXHelpers.stringAttribute(kAXTitleAttribute as String, on: window) ?? AppStrings.untitledLabel
        let frame = AXHelpers.cgRect(of: window)
        let canSetPosition = AXHelpers.isAttributeSettable(kAXPositionAttribute as String, on: window)
        let canSetSize = AXHelpers.isAttributeSettable(kAXSizeAttribute as String, on: window)
        let resizable = AXHelpers.boolAttribute("AXResizable", on: window) ?? canSetSize
        let isMainWindow = AXHelpers.boolAttribute(kAXMainAttribute as String, on: window) ?? false
        let isFocusedWindow = AXHelpers.boolAttribute(kAXFocusedAttribute as String, on: window) ?? false
        diagnostics.logMessage(
            "Frontmost window snapshot app=\(app.localizedName ?? AppStrings.unknownLabel) bundle=\(app.bundleIdentifier ?? "-") title=\(title) frame=\(frame.map { NSStringFromRect($0) } ?? "-") resizable=\(resizable) focused=\(isFocusedWindow) main=\(isMainWindow) settable(position=\(canSetPosition), size=\(canSetSize))",
            forceVisible: true
        )
    }

    static func bestFrameMatchIndex(for point: CGPoint, candidateFrames: [CGRect], tolerance: CGFloat = 8) -> Int? {
        candidateFrames.enumerated()
            .filter { _, frame in
                frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
            .min { lhs, rhs in
                squaredDistance(from: point, to: lhs.element) < squaredDistance(from: point, to: rhs.element)
            }?
            .offset
    }

    static func trafficLightHotZone(
        for windowFrame: CGRect,
        width: CGFloat = 180,
        height: CGFloat = 64,
        inset: CGFloat = 10
    ) -> CGRect {
        CGRect(
            x: windowFrame.minX - inset,
            y: windowFrame.maxY - height - inset,
            width: width + (inset * 2),
            height: height + (inset * 2)
        )
    }

    static func shouldIncludeCurrentSpaceStandardCandidate(_ candidate: WindowCandidate, activeSpaceIDs: Set<Int>) -> Bool {
        guard isStandardSubrole(candidate.subrole) else {
            return false
        }
        guard !candidate.isMinimized else {
            return false
        }
        guard let layer = candidate.layer, layer == 0 else {
            return false
        }
        if let alpha = candidate.alpha, alpha <= 0.01 {
            return false
        }
        let size = candidate.bounds?.size ?? AXHelpers.sizeAttribute(kAXSizeAttribute as String, on: candidate.axWindow)
        if let size, (size == .zero || size.width < 40 || size.height < 40) {
            return false
        }

        if !candidate.spaceIDs.isEmpty {
            return !candidate.spaceIDs.isDisjoint(with: activeSpaceIDs)
        }

        return candidate.isOnScreen
    }

    static func currentSpaceCGEntries(
        entries: [[String: AnyObject]],
        activeSpaceIDs: Set<Int>,
        spacesProvider: (CGWindowID) -> Set<Int> = WindowSpacePrivateApis.spaces(for:)
    ) -> [[String: AnyObject]] {
        entries.filter { entry in
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard layer == 0, isOnScreen else {
                return false
            }

            if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
                return false
            }

            if let bounds = boundsFromCGEntry(entry),
               (bounds.size == .zero ||
                bounds.width < 40 ||
                bounds.height < 40) {
                return false
            }

            let windowID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else {
                return false
            }

            let spaceIDs = spacesProvider(windowID)
            if !spaceIDs.isEmpty {
                return !spaceIDs.isDisjoint(with: activeSpaceIDs)
            }

            return true
        }
    }

    static func currentActiveSpaceIDs(
        entries: [[String: AnyObject]]? = nil,
        spacesProvider: (CGWindowID) -> Set<Int> = WindowSpacePrivateApis.spaces(for:)
    ) -> Set<Int> {
        let entries = entries ?? (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? [])
        var activeSpaceIDs = Set<Int>()

        for entry in entries {
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard layer == 0, isOnScreen else {
                continue
            }
            let windowID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else {
                continue
            }
            activeSpaceIDs.formUnion(spacesProvider(windowID))
        }

        return activeSpaceIDs
    }

    static func matchesRequestedIdentifier(_ identifier: String, matchingIdentifiers: Set<String>?) -> Bool {
        guard let matchingIdentifiers else {
            return true
        }
        return matchingIdentifiers.contains(identifier)
    }

    static func mapAXWindowToCGWindowID(
        _ window: AXUIElement,
        cgEntries: [[String: AnyObject]],
        excluding usedWindowIDs: Set<CGWindowID>
    ) -> CGWindowID? {
        let axTitle = (AXHelpers.stringAttribute(kAXTitleAttribute as String, on: window) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let axPosition = AXHelpers.pointAttribute(kAXPositionAttribute as String, on: window)
        let axSize = AXHelpers.sizeAttribute(kAXSizeAttribute as String, on: window)
        let tolerance: CGFloat = 2

        if !axTitle.isEmpty,
           let titleMatch = cgEntries.first(where: { entry in
               let candidateTitle = ((entry[kCGWindowName as String] as? String) ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               return !usedWindowIDs.contains(candidateID) && candidateTitle == axTitle
           }) {
            return CGWindowID((titleMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        if let axPosition, let axSize, axSize != .zero,
           let boundsMatch = cgEntries.first(where: { entry in
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               guard !usedWindowIDs.contains(candidateID),
                     let candidateBounds = boundsFromCGEntry(entry) else {
                   return false
               }
               let positionMatch = abs(candidateBounds.origin.x - axPosition.x) <= tolerance &&
                   abs(candidateBounds.origin.y - axPosition.y) <= tolerance
               let sizeMatch = abs(candidateBounds.size.width - axSize.width) <= tolerance &&
                   abs(candidateBounds.size.height - axSize.height) <= tolerance
               return positionMatch && sizeMatch
           }) {
            return CGWindowID((boundsMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        if !axTitle.isEmpty,
           let fuzzyMatch = cgEntries.first(where: { entry in
               let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
               guard !usedWindowIDs.contains(candidateID) else {
                   return false
               }
               let candidateTitle = ((entry[kCGWindowName as String] as? String) ?? "").lowercased()
               return candidateTitle.contains(axTitle.lowercased())
           }) {
            return CGWindowID((fuzzyMatch[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }

        return nil
    }

    private func candidateHitTestPoints(for location: CGPoint) -> [CGPoint] {
        var candidates = [location]
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return candidates
        }

        let localY = location.y - screen.frame.minY
        let flipped = CGPoint(x: location.x, y: screen.frame.maxY - localY)
        if abs(flipped.y - location.y) > 1 {
            candidates.append(flipped)
        }
        return candidates
    }

    private func runningApplication(for element: AXUIElement) -> NSRunningApplication? {
        let pid = AXHelpers.pid(of: element)
        guard pid != 0 else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func isLikelyInMenuBar(_ location: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return false
        }
        return location.y > screen.visibleFrame.maxY
    }

    private func resolveUsingFocusedWindowButtonLookup(
        app: NSRunningApplication,
        appElement: AXUIElement,
        candidatePoint: CGPoint,
        originalLocation: CGPoint
    ) -> ClickedWindowContext? {
        for window in focusedOrMainWindows(in: appElement) {
            guard let windowFrame = AXHelpers.cgRect(of: window) else {
                continue
            }
            let hotZone = Self.trafficLightHotZone(
                for: windowFrame,
                width: trafficLightHotZoneWidth,
                height: trafficLightHotZoneHeight,
                inset: trafficLightHotZoneInset
            )
            if !hotZone.contains(candidatePoint) {
                continue
            }

            guard let buttonElement = matchingGreenButton(in: window, clickLocation: candidatePoint) else {
                continue
            }

            return context(for: buttonElement, app: app, clickLocation: originalLocation)
        }

        return nil
    }

    private func resolveTitleBarInteractionUsingHitTest(at location: CGPoint) -> TitleBarHitTestResolution {
        let systemWideElement = AXUIElementCreateSystemWide()
        let candidatePoints = candidateHitTestPoints(for: location)

        for candidatePoint in candidatePoints {
            var hitElement: AXUIElement?
            let hitError = AXUIElementCopyElementAtPosition(systemWideElement, Float(candidatePoint.x), Float(candidatePoint.y), &hitElement)
            guard hitError == .success,
                  let hitElement,
                  let windowElement = AXHelpers.window(of: hitElement) else {
                continue
            }

            let pid = AXHelpers.pid(of: windowElement)
            guard pid != 0,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid) else {
                continue
            }

            guard let windowFrame = AXHelpers.cgRect(of: windowElement) else {
                continue
            }

            if shouldIgnoreTitleBarHitElement(
                hitElement,
                window: windowElement,
                windowFrame: windowFrame
            ) {
                return .blocked
            }

            guard let interactionResolution = titleBarInteractionResolution(for: windowElement, sourceElement: hitElement),
                  Self.shouldAcceptHitTestResolvedTitleBarInteraction(
                    originalLocation: location,
                    windowFrame: windowFrame,
                    activationRect: interactionResolution.rects.activationRect
                  ) else {
                continue
            }

            guard let context = windowContext(
                for: windowElement,
                app: app,
                clickLocation: location,
                sourceElement: hitElement,
                role: AXHelpers.stringAttribute(kAXRoleAttribute as String, on: hitElement),
                subrole: AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: hitElement),
                actions: AXHelpers.actions(for: hitElement)
            ) else {
                continue
            }

            return .resolved(TitleBarInteractionContext(
                draggableRect: interactionResolution.rects.draggableRect,
                activationRect: interactionResolution.rects.activationRect,
                allowsActivationOutsideDraggableRect: interactionResolution.allowsActivationOutsideDraggableRect,
                windowContext: context
            ))
        }

        return .miss
    }

    private func resolveGreenButton(from hitElement: AXUIElement, clickLocation: CGPoint) -> AXUIElement? {
        if let directMatch = nearestGreenButton(from: hitElement) {
            return directMatch
        }

        guard let window = AXHelpers.window(of: hitElement) else {
            return nil
        }

        if let windowFrame = AXHelpers.cgRect(of: window) {
            let hotZone = Self.trafficLightHotZone(
                for: windowFrame,
                width: trafficLightHotZoneWidth,
                height: trafficLightHotZoneHeight,
                inset: trafficLightHotZoneInset
            )
            if !hotZone.contains(clickLocation) {
                return nil
            }
        }

        return matchingGreenButton(in: window, clickLocation: clickLocation)
    }

    private func matchingGreenButton(in window: AXUIElement, clickLocation: CGPoint) -> AXUIElement? {
        let buttons = greenButtonCandidates(in: window)
        let frameMatches: [(Int, CGRect)] = buttons.enumerated().compactMap { index, button in
            guard let frame = AXHelpers.cgRect(of: button) else {
                return nil
            }
            return (index, frame)
        }

        guard let matchedFrameIndex = Self.bestFrameMatchIndex(
            for: clickLocation,
            candidateFrames: frameMatches.map { $0.1 },
            tolerance: greenButtonHitTolerance
        ) else {
            return nil
        }

        return buttons[frameMatches[matchedFrameIndex].0]
    }

    private func greenButtonCandidates(in window: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var seen = Set<Int>()

        func appendCandidate(_ element: AXUIElement) {
            let identifier = Int(CFHash(element))
            guard seen.insert(identifier).inserted else {
                return
            }
            results.append(element)
        }

        for attribute in [kAXFullScreenButtonAttribute as String, kAXZoomButtonAttribute as String] {
            if let element = AXHelpers.elementAttribute(attribute, on: window) {
                appendCandidate(element)
            }
        }

        if results.isEmpty {
            var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
            var enqueued = Set([Int(CFHash(window))])
            var visited = 0
            let maxDepth = 4
            let maxVisitedNodes = 120

            while !queue.isEmpty, visited < maxVisitedNodes {
                let current = queue.removeFirst()
                visited += 1

                let role = AXHelpers.stringAttribute(kAXRoleAttribute as String, on: current.element)
                let subrole = AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: current.element)
                if role == (kAXButtonRole as String), supportedGreenButtonSubroles.contains(subrole ?? "") {
                    appendCandidate(current.element)
                }

                guard current.depth < maxDepth else {
                    continue
                }

                let children = AXHelpers.children(of: current.element)
                let visibleChildren = AXHelpers.children(of: current.element, attribute: kAXVisibleChildrenAttribute as String)
                for child in visibleChildren + children {
                    let identifier = Int(CFHash(child))
                    if enqueued.contains(identifier) {
                        continue
                    }
                    enqueued.insert(identifier)
                    queue.append((child, current.depth + 1))
                }
            }
        }

        return results
    }

    private func focusedOrMainWindows(in appElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var seen = Set<Int>()

        func appendWindow(_ window: AXUIElement?) {
            guard let window else {
                return
            }
            let identifier = Int(CFHash(window))
            guard seen.insert(identifier).inserted else {
                return
            }
            windows.append(window)
        }

        appendWindow(AXHelpers.elementAttribute(kAXFocusedWindowAttribute as String, on: appElement))
        appendWindow(AXHelpers.elementAttribute(kAXMainWindowAttribute as String, on: appElement))

        return windows
    }

    private func nearestGreenButton(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var remainingDepth = maxAncestorTraversalDepth
        while let candidate = current, remainingDepth > 0 {
            let role = AXHelpers.stringAttribute(kAXRoleAttribute as String, on: candidate)
            let subrole = AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: candidate)
            if role == (kAXButtonRole as String), supportedGreenButtonSubroles.contains(subrole ?? "") {
                return candidate
            }
            current = AXHelpers.parent(of: candidate)
            remainingDepth -= 1
        }
        return nil
    }

    private func draggableRect(for window: AXUIElement) -> CGRect? {
        guard let windowFrame = AXHelpers.cgRect(of: window) else {
            return nil
        }

        let draggableRect: CGRect
        if let controlFrame = titleBarReferenceFrame(in: window) {
            draggableRect = Self.titleBarRect(forWindowFrame: windowFrame, controlFrame: controlFrame)
        } else if shouldUseFallbackTitleBarRect(for: window, windowFrame: windowFrame) {
            draggableRect = Self.fallbackTitleBarRect(
                forWindowFrame: windowFrame,
                fallbackTitleBarHeight: fallbackTitleBarHeight
            )
        } else {
            return nil
        }

        var resolvedRect = draggableRect
        if let toolbarFrame = toolbarFrame(in: window, windowFrame: windowFrame) {
            resolvedRect = resolvedRect.union(toolbarFrame)
        }

        return resolvedRect
    }

    private func titleBarInteractionRects(
        for window: AXUIElement,
        sourceElement: AXUIElement? = nil
    ) -> TitleBarInteractionRects? {
        guard let windowFrame = AXHelpers.cgRect(of: window),
              let draggableRect = draggableRect(for: window) else {
            return nil
        }

        var activationRect = draggableRect
        for frame in supplementaryTitleBarFrames(in: window, windowFrame: windowFrame) {
            activationRect = activationRect.union(frame)
        }
        if let sourceElement {
            for frame in supplementaryFramesAlongAncestorChain(
                from: sourceElement,
                to: window,
                windowFrame: windowFrame
            ) {
                activationRect = activationRect.union(frame)
            }
        }

        return TitleBarInteractionRects(draggableRect: draggableRect, activationRect: activationRect)
    }

    private func titleBarInteractionResolution(
        for window: AXUIElement,
        sourceElement: AXUIElement
    ) -> (rects: TitleBarInteractionRects, allowsActivationOutsideDraggableRect: Bool)? {
        guard let rects = titleBarInteractionRects(for: window, sourceElement: sourceElement),
              let windowFrame = AXHelpers.cgRect(of: window) else {
            return nil
        }

        let supplementaryFrames = supplementaryFramesAlongAncestorChain(
            from: sourceElement,
            to: window,
            windowFrame: windowFrame
        )
        let sourceFrame = AXHelpers.cgRect(of: sourceElement)
        let sourceEscapesDraggableRect = sourceFrame.map { !rects.draggableRect.contains($0) } ?? false
        let allowsActivationOutsideDraggableRect =
            !supplementaryFrames.isEmpty
            && sourceEscapesDraggableRect

        return (
            rects: rects,
            allowsActivationOutsideDraggableRect: allowsActivationOutsideDraggableRect
        )
    }

    private func titleBarReferenceFrame(in window: AXUIElement) -> CGRect? {
        guard let windowFrame = AXHelpers.cgRect(of: window) else {
            return nil
        }

        var candidates: [CGRect] = []
        for attribute in [
            kAXCloseButtonAttribute as String,
            kAXZoomButtonAttribute as String,
            kAXFullScreenButtonAttribute as String,
            kAXMinimizeButtonAttribute as String
        ] {
            if let element = AXHelpers.elementAttribute(attribute, on: window),
               let frame = AXHelpers.cgRect(of: element) {
                candidates.append(frame)
            }
        }

        return candidates
            .filter { Self.isLikelyTitleBarControlFrame($0, in: windowFrame, fallbackTitleBarHeight: fallbackTitleBarHeight) }
            .min { lhs, rhs in
                if abs(lhs.minY - rhs.minY) > 1 {
                    return lhs.minY < rhs.minY
                }
                return lhs.minX < rhs.minX
            }
    }

    private func toolbarFrame(in window: AXUIElement, windowFrame: CGRect) -> CGRect? {
        for child in AXHelpers.children(of: window) {
            let role = AXHelpers.stringAttribute(kAXRoleAttribute as String, on: child)
            if role == (kAXToolbarRole as String) || role == (kAXGroupRole as String),
               let frame = AXHelpers.cgRect(of: child),
               Self.isLikelyTitleBarSupplementaryFrame(frame, in: windowFrame, fallbackTitleBarHeight: fallbackTitleBarHeight) {
                return frame
            }
        }
        return nil
    }

    private func supplementaryTitleBarFrames(in window: AXUIElement, windowFrame: CGRect) -> [CGRect] {
        var frames: [CGRect] = []
        var queue: [(element: AXUIElement, depth: Int)] = AXHelpers.children(of: window).map { ($0, 1) }
        var enqueued = Set(queue.map { Int(CFHash($0.element)) })
        var visited = 0
        let maxDepth = 5
        let maxVisitedNodes = 160

        while !queue.isEmpty, visited < maxVisitedNodes {
            let current = queue.removeFirst()
            visited += 1

            let role = AXHelpers.stringAttribute(kAXRoleAttribute as String, on: current.element)
            if titleBarSupplementaryRoles.contains(role ?? ""),
               let frame = AXHelpers.cgRect(of: current.element),
               Self.isLikelyTitleBarSupplementaryFrame(frame, in: windowFrame, fallbackTitleBarHeight: fallbackTitleBarHeight) {
                frames.append(frame)
            }

            guard current.depth < maxDepth else {
                continue
            }

            let children = AXHelpers.children(of: current.element)
            let visibleChildren = AXHelpers.children(of: current.element, attribute: kAXVisibleChildrenAttribute as String)
            for child in visibleChildren + children {
                let identifier = Int(CFHash(child))
                guard enqueued.insert(identifier).inserted else {
                    continue
                }
                queue.append((child, current.depth + 1))
            }
        }

        return frames
    }

    private func hasTrustedFallbackTitleBarEvidence(
        in window: AXUIElement,
        windowFrame: CGRect,
        preferredLocation: CGPoint
    ) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()

        let samplePoints = Self.fallbackTitleBarProbePoints(for: windowFrame)
            .sorted { lhs, rhs in
                hypot(lhs.x - preferredLocation.x, lhs.y - preferredLocation.y)
                    < hypot(rhs.x - preferredLocation.x, rhs.y - preferredLocation.y)
            }

        for point in samplePoints.prefix(1) {
            var hitElement: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWideElement, Float(point.x), Float(point.y), &hitElement) == .success,
                  let hitElement,
                  let hitWindow = AXHelpers.window(of: hitElement),
                  AXHelpers.elementsEqual(hitWindow, window) else {
                continue
            }

            let ancestors = titleBarHitAncestors(from: hitElement, to: window)
            if Self.isTrustedFallbackTitleBarHitPath(
                ancestors,
                in: windowFrame,
                fallbackTitleBarHeight: fallbackTitleBarHeight
            ) {
                return true
            }
        }

        return false
    }

    private func hasReliableFallbackTitleBarEvidence(
        in window: AXUIElement,
        windowFrame: CGRect,
        preferredLocation: CGPoint
    ) -> Bool {
        if titleBarReferenceFrame(in: window) != nil {
            return true
        }

        return hasTrustedFallbackTitleBarEvidence(
            in: window,
            windowFrame: windowFrame,
            preferredLocation: preferredLocation
        )
    }

    private func supplementaryFramesAlongAncestorChain(
        from element: AXUIElement,
        to window: AXUIElement,
        windowFrame: CGRect
    ) -> [CGRect] {
        var frames: [CGRect] = []
        var current: AXUIElement? = element
        var remainingDepth = maxAncestorTraversalDepth

        while let candidate = current, remainingDepth > 0 {
            if let frame = AXHelpers.cgRect(of: candidate),
               Self.isLikelyTitleBarSupplementaryFrame(frame, in: windowFrame, fallbackTitleBarHeight: fallbackTitleBarHeight) {
                frames.append(frame)
            }
            if AXHelpers.elementsEqual(candidate, window) {
                break
            }
            current = AXHelpers.parent(of: candidate)
            remainingDepth -= 1
        }

        return frames
    }

    private func shouldIgnoreTitleBarHitElement(
        _ element: AXUIElement,
        window: AXUIElement,
        windowFrame: CGRect
    ) -> Bool {
        _ = windowFrame
        let ancestors = titleBarHitAncestors(from: element, to: window)

        if Self.isLikelyTabStripTab(roles: ancestors.map(\.role), frames: ancestors.map(\.frame)) {
            return true
        }

        for ancestor in ancestors {
            if Self.isInteractiveTitleBarElement(role: ancestor.role, actions: ancestor.actions) {
                return true
            }
        }

        return false
    }

    private func titleBarHitAncestors(from element: AXUIElement, to window: AXUIElement) -> [TitleBarHitAncestor] {
        var ancestors: [TitleBarHitAncestor] = []
        var current: AXUIElement? = element
        var remainingDepth = maxAncestorTraversalDepth

        while let candidate = current, remainingDepth > 0 {
            ancestors.append(
                TitleBarHitAncestor(
                    role: AXHelpers.stringAttribute(kAXRoleAttribute as String, on: candidate),
                    actions: AXHelpers.actions(for: candidate),
                    frame: AXHelpers.cgRect(of: candidate)
                )
            )

            if AXHelpers.elementsEqual(candidate, window) {
                break
            }
            current = AXHelpers.parent(of: candidate)
            remainingDepth -= 1
        }

        return ancestors
    }

    static func isLikelyTitleBarSupplementaryFrame(
        _ frame: CGRect,
        in windowFrame: CGRect,
        fallbackTitleBarHeight: CGFloat = 56
    ) -> Bool {
        guard !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let topInset = frame.minY - windowFrame.minY
        guard topInset >= -4, topInset <= 24 else {
            return false
        }

        let maxReasonableHeight = min(
            max(fallbackTitleBarHeight * 1.75, 96),
            max(windowFrame.height * 0.35, fallbackTitleBarHeight)
        )
        guard frame.height <= maxReasonableHeight else {
            return false
        }

        let bottomExtent = frame.maxY - windowFrame.minY
        return bottomExtent <= maxReasonableHeight + 24
    }

    static func isLikelyTitleBarControlFrame(
        _ frame: CGRect,
        in windowFrame: CGRect,
        fallbackTitleBarHeight: CGFloat = 56
    ) -> Bool {
        guard !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let maxControlWidth = max(96, fallbackTitleBarHeight * 1.5)
        let maxControlHeight = max(32, fallbackTitleBarHeight)
        guard frame.width <= maxControlWidth,
              frame.height <= maxControlHeight else {
            return false
        }

        let topInset = frame.minY - windowFrame.minY
        guard topInset >= -4, topInset <= max(24, fallbackTitleBarHeight * 0.75) else {
            return false
        }

        let bottomExtent = frame.maxY - windowFrame.minY
        return bottomExtent <= max(fallbackTitleBarHeight * 1.25, 84)
    }

    static func titleBarRect(forWindowFrame windowFrame: CGRect, controlFrame: CGRect) -> CGRect {
        let topInset = max(0, controlFrame.minY - windowFrame.minY)
        let height = min(
            max(controlFrame.height + (2 * topInset), controlFrame.height),
            windowFrame.height
        )
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: height
        )
    }

    static func fallbackTitleBarRect(
        forWindowFrame windowFrame: CGRect,
        fallbackTitleBarHeight: CGFloat
    ) -> CGRect {
        let height = min(fallbackTitleBarHeight, windowFrame.height)
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: height
        )
    }

    static func shouldAcceptHitTestResolvedTitleBarInteraction(
        originalLocation: CGPoint,
        windowFrame: CGRect,
        activationRect: CGRect
    ) -> Bool {
        windowFrame.contains(originalLocation) && activationRect.contains(originalLocation)
    }

    static func shouldAcceptFallbackTitleBarInteraction(
        originalLocation: CGPoint,
        windowFrame: CGRect?,
        draggableRect: CGRect,
        hasReliableFallbackEvidence: Bool
    ) -> Bool {
        guard hasReliableFallbackEvidence, let windowFrame else {
            return false
        }
        return windowFrame.contains(originalLocation) && draggableRect.contains(originalLocation)
    }

    static func fallbackTitleBarProbePoints(for windowFrame: CGRect) -> [CGPoint] {
        let yInset = min(26, max(12, min(windowFrame.height * 0.14, 72)))
        let y = windowFrame.minY + yInset
        return [0.22, 0.5, 0.78].map { xFraction in
            CGPoint(x: windowFrame.minX + (windowFrame.width * xFraction), y: y)
        }
    }

    static func isTrustedFallbackTitleBarHitPath(
        _ ancestors: [TitleBarHitAncestor],
        in windowFrame: CGRect,
        fallbackTitleBarHeight: CGFloat = 56
    ) -> Bool {
        let roles = ancestors.map(\.role)
        let frames = ancestors.map(\.frame)

        if isLikelyTabStripTab(roles: roles, frames: frames) {
            return false
        }

        if ancestors.contains(where: { isInteractiveTitleBarElement(role: $0.role, actions: $0.actions) }) {
            return false
        }

        if roles.first == kAXWindowRole as String {
            return true
        }

        if roles.contains(kAXStaticTextRole as String) || roles.contains(kAXImageRole as String) {
            return true
        }

        if roles.contains(kAXToolbarRole as String) {
            return true
        }

        return ancestors.contains { ancestor in
            guard let role = ancestor.role,
                  role == (kAXGroupRole as String) || role == "AXSplitGroup",
                  let frame = ancestor.frame else {
                return false
            }
            return isLikelyTitleBarSupplementaryFrame(
                frame,
                in: windowFrame,
                fallbackTitleBarHeight: fallbackTitleBarHeight
            )
        }
    }

    static func isInteractiveTitleBarElement(role: String?, actions: [String]) -> Bool {
        let interactiveRoles: Set<String> = [
            kAXButtonRole as String,
            kAXRadioButtonRole as String,
            kAXCheckBoxRole as String,
            kAXPopUpButtonRole as String,
            kAXMenuButtonRole as String,
            kAXComboBoxRole as String,
            kAXTextFieldRole as String,
            "AXSearchField",
            kAXSliderRole as String,
            kAXIncrementorRole as String
        ]
        let passiveRoles: Set<String> = [
            kAXStaticTextRole as String,
            kAXImageRole as String,
            kAXGroupRole as String,
            kAXToolbarRole as String,
            kAXWindowRole as String
        ]
        let interactiveActions: Set<String> = [
            kAXPressAction as String,
            kAXConfirmAction as String,
            kAXIncrementAction as String,
            kAXDecrementAction as String
        ]

        if let role, interactiveRoles.contains(role) {
            return true
        }

        if let role, passiveRoles.contains(role) {
            return false
        }

        return !interactiveActions.isDisjoint(with: Set(actions))
    }

    static func isLikelyTabStripTab(roles: [String?], frames: [CGRect?]) -> Bool {
        guard let tabGroupIndex = roles.firstIndex(where: { $0 == "AXTabGroup" }),
              tabGroupIndex >= 2,
              roles[0] == kAXGroupRole as String,
              roles[1] == kAXGroupRole as String,
              let leafFrame = frames[0],
              let parentFrame = frames[1],
              let tabGroupFrame = frames[tabGroupIndex] else {
            return false
        }

        let frameTolerance: CGFloat = 2
        let sameLeafAndParentFrame =
            abs(leafFrame.minX - parentFrame.minX) <= frameTolerance
            && abs(leafFrame.minY - parentFrame.minY) <= frameTolerance
            && abs(leafFrame.width - parentFrame.width) <= frameTolerance
            && abs(leafFrame.height - parentFrame.height) <= frameTolerance
        guard sameLeafAndParentFrame else {
            return false
        }

        let widthDelta = tabGroupFrame.width - leafFrame.width
        let heightDelta = abs(tabGroupFrame.height - leafFrame.height)
        return widthDelta >= 12 && heightDelta <= 6
    }

    private func shouldUseFallbackTitleBarRect(for window: AXUIElement, windowFrame: CGRect) -> Bool {
        guard Self.roleIsWindow(window) else {
            return false
        }
        let subrole = AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: window)
        guard Self.isStandardSubrole(subrole) else {
            return false
        }
        guard windowFrame.width >= minimumCandidateWindowSize.width,
              windowFrame.height >= minimumCandidateWindowSize.height else {
            return false
        }
        let canSetSize = AXHelpers.isAttributeSettable(kAXSizeAttribute as String, on: window)
        let resizable = AXHelpers.boolAttribute("AXResizable", on: window) ?? canSetSize
        guard resizable, canSetSize else {
            return false
        }
        let isMainWindow = AXHelpers.boolAttribute(kAXMainAttribute as String, on: window) ?? false
        let isFocusedWindow = AXHelpers.boolAttribute(kAXFocusedAttribute as String, on: window) ?? false
        return isMainWindow || isFocusedWindow
    }

    private func shouldEnumerateWindows(for app: NSRunningApplication) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        if app.isTerminated {
            return false
        }
        if app.activationPolicy == .prohibited {
            return false
        }
        return true
    }

    private func rawAppWindows(in appElement: AXUIElement) -> [AXUIElement] {
        guard let rawWindows = AXHelpers.value(of: kAXWindowsAttribute as String, on: appElement) as? [AXUIElement] else {
            return []
        }
        return rawWindows
    }

    private func rawAppWindows(for app: NSRunningApplication) -> [AXUIElement] {
        rawAppWindows(in: AXUIElementCreateApplication(app.processIdentifier))
    }

    private func windowCandidates(
        windows: [AXUIElement],
        cgEntries: [[String: AnyObject]],
        spacesProvider: (CGWindowID) -> Set<Int>
    ) -> [WindowCandidate] {
        let cgEntriesByWindowID: [CGWindowID: [String: AnyObject]] = Dictionary(uniqueKeysWithValues: cgEntries.compactMap { entry in
            let windowID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else {
                return nil
            }
            return (windowID, entry)
        })
        var usedWindowIDs = Set<CGWindowID>()

        return windows.compactMap { window in
            makeWindowCandidate(
                window,
                cgEntries: cgEntries,
                cgEntriesByWindowID: cgEntriesByWindowID,
                spacesProvider: spacesProvider,
                usedWindowIDs: &usedWindowIDs
            )
        }
    }

    private func makeWindowCandidate(
        _ window: AXUIElement,
        cgEntries: [[String: AnyObject]],
        cgEntriesByWindowID: [CGWindowID: [String: AnyObject]],
        spacesProvider: (CGWindowID) -> Set<Int>,
        usedWindowIDs: inout Set<CGWindowID>
    ) -> WindowCandidate? {
        let resolvedWindowID = resolveCGWindowID(for: window, cgEntries: cgEntries, usedWindowIDs: &usedWindowIDs)
        let matchingEntry = resolvedWindowID.flatMap { cgEntriesByWindowID[$0] }
        let bounds = matchingEntry.flatMap(Self.boundsFromCGEntry)
        let layer = matchingEntry.flatMap { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue }
        let alpha = matchingEntry.flatMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue }
        let isOnScreen = matchingEntry.flatMap { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue } ?? false
        let subrole = AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: window)
        let isMinimized = AXHelpers.boolAttribute(kAXMinimizedAttribute as String, on: window) ?? false
        let size = bounds?.size ?? AXHelpers.sizeAttribute(kAXSizeAttribute as String, on: window)
        let shouldResolveSpaces = Self.shouldResolveSpaces(
            subrole: subrole,
            layer: layer,
            alpha: alpha,
            size: size,
            isMinimized: isMinimized
        )
        let spaceIDs = shouldResolveSpaces ? (resolvedWindowID.map(spacesProvider) ?? []) : []

        return WindowCandidate(
            axWindow: window,
            cgWindowID: resolvedWindowID,
            bounds: bounds,
            layer: layer,
            alpha: alpha,
            isOnScreen: isOnScreen,
            subrole: subrole,
            spaceIDs: spaceIDs,
            isMinimized: isMinimized
        )
    }

    private func resolveCGWindowID(
        for window: AXUIElement,
        cgEntries: [[String: AnyObject]],
        usedWindowIDs: inout Set<CGWindowID>
    ) -> CGWindowID? {
        if let directWindowID = WindowSpacePrivateApis.windowID(for: window), directWindowID != 0 {
            usedWindowIDs.insert(directWindowID)
            return directWindowID
        }

        let fallbackWindowID = Self.mapAXWindowToCGWindowID(window, cgEntries: cgEntries, excluding: usedWindowIDs)
        if let fallbackWindowID {
            usedWindowIDs.insert(fallbackWindowID)
        }
        return fallbackWindowID
    }

    private func context(for buttonElement: AXUIElement, app: NSRunningApplication, clickLocation: CGPoint) -> ClickedWindowContext? {
        guard let windowElement = AXHelpers.window(of: buttonElement) else {
            diagnostics.logMessage("AX hit-test found green button but no parent window for pid=\(app.processIdentifier).")
            return nil
        }

        return windowContext(
            for: windowElement,
            app: app,
            clickLocation: clickLocation,
            sourceElement: buttonElement,
            role: AXHelpers.stringAttribute(kAXRoleAttribute as String, on: buttonElement),
            subrole: AXHelpers.stringAttribute(kAXSubroleAttribute as String, on: buttonElement),
            actions: AXHelpers.actions(for: buttonElement)
        )
    }

    private func batchWindowContext(for candidate: WindowCandidate, app: NSRunningApplication) -> ClickedWindowContext? {
        let windowElement = candidate.axWindow
        let windowTitle = AXHelpers.stringAttribute(kAXTitleAttribute as String, on: windowElement)
        let windowNumber = AXHelpers.windowNumber(of: windowElement)
        let windowFrame = candidate.bounds ?? AXHelpers.cgRect(of: windowElement)
        let canSetPosition = AXHelpers.isAttributeSettable(kAXPositionAttribute as String, on: windowElement)
        let canSetSize = AXHelpers.isAttributeSettable(kAXSizeAttribute as String, on: windowElement)
        let resizable = AXHelpers.boolAttribute("AXResizable", on: windowElement) ?? canSetSize
        let isFullScreen = AXHelpers.boolAttribute("AXFullScreen", on: windowElement) ?? false
        let identifier = resolvedWindowIdentifier(
            for: windowElement,
            pid: app.processIdentifier,
            cgWindowID: candidate.cgWindowID,
            windowNumber: windowNumber,
            title: windowTitle
        )

        return ClickedWindowContext(
            appName: app.localizedName ?? AppStrings.unknownAppLabel,
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier,
            clickLocation: .zero,
            buttonElement: windowElement,
            windowElement: windowElement,
            windowIdentifier: identifier,
            windowNumber: windowNumber,
            windowTitle: windowTitle,
            elementRole: kAXWindowRole as String,
            elementSubrole: candidate.subrole,
            availableActions: [],
            windowFrame: windowFrame,
            canSetPosition: canSetPosition,
            canSetSize: canSetSize,
            isResizable: resizable,
            isFullScreen: isFullScreen,
            isMainWindow: false,
            isFocusedWindow: false
        )
    }

    private func windowContext(
        for windowElement: AXUIElement,
        app: NSRunningApplication,
        clickLocation: CGPoint,
        sourceElement: AXUIElement,
        role: String?,
        subrole: String?,
        actions: [String],
        appElement: AXUIElement? = nil,
        focusedWindow: AXUIElement? = nil,
        mainWindow: AXUIElement? = nil
    ) -> ClickedWindowContext? {
        let appElement = appElement ?? AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = focusedWindow ?? AXHelpers.elementAttribute(kAXFocusedWindowAttribute as String, on: appElement)
        let mainWindow = mainWindow ?? AXHelpers.elementAttribute(kAXMainWindowAttribute as String, on: appElement)
        let windowTitle = AXHelpers.stringAttribute(kAXTitleAttribute as String, on: windowElement)
        let windowFrame = AXHelpers.cgRect(of: windowElement)
        let canSetPosition = AXHelpers.isAttributeSettable(kAXPositionAttribute as String, on: windowElement)
        let canSetSize = AXHelpers.isAttributeSettable(kAXSizeAttribute as String, on: windowElement)
        let resizable = AXHelpers.boolAttribute("AXResizable", on: windowElement) ?? canSetSize
        let isFullScreen = AXHelpers.boolAttribute("AXFullScreen", on: windowElement) ?? false
        let windowNumber = AXHelpers.windowNumber(of: windowElement)
        let identifier = resolvedWindowIdentifier(
            for: windowElement,
            pid: app.processIdentifier,
            windowNumber: windowNumber,
            title: windowTitle
        )
        let isMainWindow = AXHelpers.boolAttribute(kAXMainAttribute as String, on: windowElement)
            ?? AXHelpers.elementsEqual(windowElement, mainWindow)
        let isFocusedWindow = AXHelpers.boolAttribute(kAXFocusedAttribute as String, on: windowElement)
            ?? AXHelpers.elementsEqual(windowElement, focusedWindow)

        return ClickedWindowContext(
            appName: app.localizedName ?? AppStrings.unknownAppLabel,
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier,
            clickLocation: clickLocation,
            buttonElement: sourceElement,
            windowElement: windowElement,
            windowIdentifier: identifier,
            windowNumber: windowNumber,
            windowTitle: windowTitle,
            elementRole: role,
            elementSubrole: subrole,
            availableActions: actions,
            windowFrame: windowFrame,
            canSetPosition: canSetPosition,
            canSetSize: canSetSize,
            isResizable: resizable,
            isFullScreen: isFullScreen,
            isMainWindow: isMainWindow,
            isFocusedWindow: isFocusedWindow
        )
    }

    private func resolvedWindowIdentifier(
        for windowElement: AXUIElement,
        pid: pid_t,
        cgWindowID: CGWindowID? = nil,
        windowNumber: Int?,
        title: String?
    ) -> String {
        let resolvedCGWindowID = resolveStableCGWindowID(
            for: windowElement,
            pid: pid,
            preferredWindowID: cgWindowID
        )
        return Self.makeWindowIdentifier(
            pid: pid,
            cgWindowID: resolvedCGWindowID,
            windowNumber: windowNumber,
            title: title
        )
    }

    private func resolveStableCGWindowID(
        for windowElement: AXUIElement,
        pid: pid_t,
        preferredWindowID: CGWindowID? = nil
    ) -> CGWindowID? {
        if let preferredWindowID, preferredWindowID != 0 {
            return preferredWindowID
        }

        if let directWindowID = WindowSpacePrivateApis.windowID(for: windowElement), directWindowID != 0 {
            return directWindowID
        }

        return Self.mapAXWindowToCGWindowID(
            windowElement,
            cgEntries: Self.cgWindowEntries(for: pid),
            excluding: []
        )
    }

    static func makeWindowIdentifier(
        pid: pid_t,
        cgWindowID: CGWindowID?,
        windowNumber: Int?,
        title: String?
    ) -> String {
        if let cgWindowID, cgWindowID != 0 {
            return "pid:\(pid)-cgwindow:\(cgWindowID)"
        }

        if let windowNumber {
            return "pid:\(pid)-window:\(windowNumber)"
        }

        if let title, !title.isEmpty {
            return "pid:\(pid)-title:\(title)"
        }

        return "pid:\(pid)-window:unknown"
    }

    private static func cgWindowEntries(for pid: pid_t) -> [[String: AnyObject]] {
        let rawEntries = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
        return rawEntries.filter { entry in
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return ownerPID == pid
        }
    }

    private static func boundsFromCGEntry(_ entry: [String: AnyObject]) -> CGRect? {
        guard let rawBounds = entry[kCGWindowBounds as String] as? [String: AnyObject] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
    }

    private static func roleIsWindow(_ window: AXUIElement) -> Bool {
        guard let role = AXHelpers.stringAttribute(kAXRoleAttribute as String, on: window) else {
            return true
        }
        return role == (kAXWindowRole as String)
    }

    private static func isStandardSubrole(_ subrole: String?) -> Bool {
        guard let subrole else {
            return true
        }
        if subrole.isEmpty {
            return true
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }

    private static func shouldResolveSpaces(
        subrole: String?,
        layer: Int?,
        alpha: Double?,
        size: CGSize?,
        isMinimized: Bool
    ) -> Bool {
        guard isStandardSubrole(subrole) else {
            return false
        }
        guard !isMinimized else {
            return false
        }
        guard let layer, layer == 0 else {
            return false
        }
        if let alpha, alpha <= 0.01 {
            return false
        }
        if let size, (size == .zero || size.width < 40 || size.height < 40) {
            return false
        }
        return true
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx) + (dy * dy)
    }

    private static func cgWindowEntries() -> [[String: AnyObject]] {
        CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
    }
}
