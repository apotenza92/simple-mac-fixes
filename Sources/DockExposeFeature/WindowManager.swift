import AppKit
import ApplicationServices

enum WindowManager {
    private static let braveBundleIdentifier = "com.brave.Browser"
    private static let braveAuxiliarySubroles: Set<String> = [
        "AXFloatingWindow",
        "AXSystemFloatingWindow",
        "AXUnknown"
    ]
    private static let minimumCandidateWindowSize = CGSize(width: 100, height: 100)

    private struct WindowCandidate {
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

    struct AppExposeWindowCountDiagnostics {
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let axCount: Int
        let cgsCrossSpaceCount: Int
        let finalCount: Int
        let usedFallbackOrAugmentation: Bool
        let queryDurationMs: Int
        let phaseSummary: String?

        var summary: String {
            var parts = "bundle=\(bundleIdentifier) pid=\(processIdentifier) ax=\(axCount) cgsCrossSpace=\(cgsCrossSpaceCount) final=\(finalCount) fallbackOrAugmented=\(usedFallbackOrAugmentation) durationMs=\(queryDurationMs)"
            if let phaseSummary, !phaseSummary.isEmpty {
                parts += " phases=[\(phaseSummary)]"
            }
            return parts
        }
    }

    private struct AppExposeCountPhaseTimings {
        var axMs = 0
        var axFilterMs = 0
        var managedSpacesMs = 0
        var cgsWindowIDsMs = 0
        var relatedPIDsMs = 0
        var cgEntriesMs = 0
        var activeSpacesMs = 0
        var cgsFilterMs = 0

        var summary: String {
            [
                "ax=\(axMs)",
                "axFilter=\(axFilterMs)",
                "managedSpaces=\(managedSpacesMs)",
                "cgsIDs=\(cgsWindowIDsMs)",
                "relatedPIDs=\(relatedPIDsMs)",
                "cgEntries=\(cgEntriesMs)",
                "activeSpaces=\(activeSpacesMs)",
                "cgsFilter=\(cgsFilterMs)"
            ].joined(separator: ",")
        }
    }

    private struct WindowQueryCacheEntry<Value> {
        let value: Value
        let expiresAt: Date
    }

    private final class WindowQueryCacheObserver {
        private var observers: [NSObjectProtocol] = []

        init() {
            let center = NSWorkspace.shared.notificationCenter
            let invalidateWindowsAndRelatedProcesses: (Notification) -> Void = { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                WindowManager.invalidateWindowQueryCache(bundleIdentifier: app?.bundleIdentifier,
                                                         includeRelatedProcessIDs: true)
            }
            let invalidateWindowsOnly: (Notification) -> Void = { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                WindowManager.invalidateWindowQueryCache(bundleIdentifier: app?.bundleIdentifier,
                                                         includeRelatedProcessIDs: false)
            }

            observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsAndRelatedProcesses))
            observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsAndRelatedProcesses))
            observers.append(center.addObserver(forName: NSWorkspace.didHideApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsOnly))
            observers.append(center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsOnly))
            observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsOnly))
            observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                                object: nil,
                                                queue: .main,
                                                using: invalidateWindowsOnly))
        }
    }

    private static let windowQueryCacheTTL: TimeInterval = 0.5
    private static let relatedProcessIDsCacheTTL: TimeInterval = 60.0
    private static let windowQueryCacheLock = NSLock()
        private static var appExposeWindowCountCache: [String: WindowQueryCacheEntry<AppExposeWindowCountDiagnostics>] = [:]
        private static var relatedProcessIDsCache: [String: WindowQueryCacheEntry<Set<pid_t>>] = [:]
    private static let windowQueryCacheObserver = WindowQueryCacheObserver()
    private static let appExposePrewarmQueue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.appExposeWindowCount",
                                                             qos: .userInitiated)
    private static var appExposePrewarmInFlight: Set<String> = []
    private static var appExposePrewarmCompletions: [String: [(AppExposeWindowCountDiagnostics) -> Void]] = [:]


    static func invalidateWindowQueryCache(bundleIdentifier: String? = nil,
                                           includeRelatedProcessIDs: Bool = false) {
        _ = windowQueryCacheObserver
        windowQueryCacheLock.lock()
        defer { windowQueryCacheLock.unlock() }

        if let bundleIdentifier {
            appExposeWindowCountCache.removeValue(forKey: bundleIdentifier)
            if includeRelatedProcessIDs {
                relatedProcessIDsCache.removeValue(forKey: bundleIdentifier)
            }
            appExposePrewarmInFlight.remove(bundleIdentifier)
            return
        }

        appExposeWindowCountCache.removeAll()
        if includeRelatedProcessIDs {
            relatedProcessIDsCache.removeAll()
        }
        appExposePrewarmInFlight.removeAll()
    }

    static func prewarmAppExposeWindowCount(bundleIdentifier: String) {
        _ = windowQueryCacheObserver
        let now = Date()

        windowQueryCacheLock.lock()
        if let entry = appExposeWindowCountCache[bundleIdentifier], entry.expiresAt > now {
            windowQueryCacheLock.unlock()
            return
        }
        guard !appExposePrewarmInFlight.contains(bundleIdentifier) else {
            windowQueryCacheLock.unlock()
            return
        }
        appExposePrewarmInFlight.insert(bundleIdentifier)
        windowQueryCacheLock.unlock()

        appExposePrewarmQueue.async {
            let diagnostics = appExposeWindowCountDiagnostics(bundleIdentifier: bundleIdentifier)
            Logger.debug("APP_EXPOSE_WINDOW_COUNT: prewarmed \(diagnostics.summary)")

            windowQueryCacheLock.lock()
            appExposePrewarmInFlight.remove(bundleIdentifier)
            let completions = appExposePrewarmCompletions.removeValue(forKey: bundleIdentifier) ?? []
            windowQueryCacheLock.unlock()

            guard !completions.isEmpty else { return }
            DispatchQueue.main.async {
                for completion in completions {
                    completion(diagnostics)
                }
            }
        }
    }

    static func whenAppExposeWindowCountPrewarmCompletes(
        bundleIdentifier: String,
        completion: @escaping (AppExposeWindowCountDiagnostics) -> Void
    ) {
        if let cached = cachedAppExposeWindowCountDiagnosticsIfAvailable(for: bundleIdentifier) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }

        windowQueryCacheLock.lock()
        appExposePrewarmCompletions[bundleIdentifier, default: []].append(completion)
        let shouldStartPrewarm = !appExposePrewarmInFlight.contains(bundleIdentifier)
        windowQueryCacheLock.unlock()

        if shouldStartPrewarm {
            prewarmAppExposeWindowCount(bundleIdentifier: bundleIdentifier)
        }
    }

    static func appExposeWindowCountDiagnosticsAfterPrewarmIfAvailable(bundleIdentifier: String) -> AppExposeWindowCountDiagnostics? {
        cachedAppExposeWindowCountDiagnosticsIfAvailable(for: bundleIdentifier)
    }

    private static func cachedWindowQueryValue<Value>(
        for bundleIdentifier: String,
        cache: inout [String: WindowQueryCacheEntry<Value>],
        ttl: TimeInterval = windowQueryCacheTTL,
        compute: () -> Value
    ) -> Value {
        _ = windowQueryCacheObserver
        let now = Date()

        windowQueryCacheLock.lock()
        if let entry = cache[bundleIdentifier], entry.expiresAt > now {
            let value = entry.value
            windowQueryCacheLock.unlock()
            return value
        }
        windowQueryCacheLock.unlock()

        let value = compute()

        windowQueryCacheLock.lock()
        cache[bundleIdentifier] = WindowQueryCacheEntry(value: value,
                                                        expiresAt: now.addingTimeInterval(ttl))
        windowQueryCacheLock.unlock()
        return value
    }

    private static func cachedAppExposeWindowCountDiagnostics(
        for bundleIdentifier: String,
        compute: () -> AppExposeWindowCountDiagnostics
    ) -> AppExposeWindowCountDiagnostics {
        _ = windowQueryCacheObserver
        let now = Date()

        windowQueryCacheLock.lock()
        if let entry = appExposeWindowCountCache[bundleIdentifier], entry.expiresAt > now {
            let value = entry.value
            windowQueryCacheLock.unlock()
            return value
        }
        windowQueryCacheLock.unlock()

        let value = compute()

        windowQueryCacheLock.lock()
        appExposeWindowCountCache[bundleIdentifier] = WindowQueryCacheEntry(
            value: value,
            expiresAt: now.addingTimeInterval(windowQueryCacheTTL)
        )
        windowQueryCacheLock.unlock()
        return value
    }

    private static func cachedAppExposeWindowCountDiagnosticsIfAvailable(
        for bundleIdentifier: String
    ) -> AppExposeWindowCountDiagnostics? {
        _ = windowQueryCacheObserver
        let now = Date()

        windowQueryCacheLock.lock()
        defer { windowQueryCacheLock.unlock() }

        guard let entry = appExposeWindowCountCache[bundleIdentifier], entry.expiresAt > now else {
            return nil
        }
        return entry.value
    }

    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        invalidateWindowQueryCache(bundleIdentifier: app.bundleIdentifier)
        return app.activate()
    }

    
    
    
    
    
    


    /// Count windows for App Exposé gating across all Mission Control Spaces.
    static func appExposeWindowCount(bundleIdentifier: String) -> Int {
        appExposeWindowCountDiagnostics(bundleIdentifier: bundleIdentifier).finalCount
    }

    static func appExposeWindowCountDiagnostics(bundleIdentifier: String) -> AppExposeWindowCountDiagnostics {
        cachedAppExposeWindowCountDiagnostics(for: bundleIdentifier) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                return AppExposeWindowCountDiagnostics(bundleIdentifier: bundleIdentifier,
                                                       processIdentifier: 0,
                                                       axCount: 0,
                                                       cgsCrossSpaceCount: 0,
                                                       finalCount: 0,
                                                       usedFallbackOrAugmentation: false,
                                                       queryDurationMs: Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000),
                                                       phaseSummary: nil)
            }

            var phases = AppExposeCountPhaseTimings()
            var phaseStartedAt = CFAbsoluteTimeGetCurrent()
            let rawCGEntries = allCGWindowEntries()
            let fullScreenSpaceIDs = WindowSpacePrivateApis.fullScreenSpaceIDs()
            let allCandidates = windowCandidates(for: app,
                                                 includeSpaceIDs: false,
                                                 rawCGEntries: rawCGEntries)
            // App Exposé never shows full-screen windows, so counting them would open
            // App Exposé with nothing, or only one window, to choose from.
            let candidates = allCandidates.filter {
                !isFullScreenWindow($0, fullScreenSpaceIDs: fullScreenSpaceIDs)
            }
            phases.axMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)

            phaseStartedAt = CFAbsoluteTimeGetCurrent()
            let axWindowIDs = Set(candidates.compactMap(\.cgWindowID))
            let strictAXCount = candidates.filter {
                shouldIncludeGlobalStandardCandidate($0, bundleIdentifier: app.bundleIdentifier)
            }.count
            let axCount = strictAXCount > 0 ? strictAXCount : relaxedAppExposeAXWindowCount(from: candidates)
            phases.axFilterMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)

            let cgsCount = axCount >= 2
                ? axCount
                : cgsCrossSpaceStandardWindowCount(for: app,
                                                   excludingAXWindowIDs: axWindowIDs,
                                                   rawCGEntries: rawCGEntries,
                                                   stopAt: 2,
                                                   phases: &phases)
            let finalCount = min(max(axCount, cgsCount), 2)
            let usedFallbackOrAugmentation = cgsCount > axCount

            let diagnostics = AppExposeWindowCountDiagnostics(bundleIdentifier: bundleIdentifier,
                                                              processIdentifier: app.processIdentifier,
                                                              axCount: axCount,
                                                              cgsCrossSpaceCount: cgsCount,
                                                              finalCount: finalCount,
                                                              usedFallbackOrAugmentation: usedFallbackOrAugmentation,
                                                              queryDurationMs: Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000),
                                                              phaseSummary: phases.summary)
            Logger.debug("APP_EXPOSE_WINDOW_COUNT: \(diagnostics.summary)")
            return diagnostics
        }
    }


    /// Get the main window of an app
    static func getMainWindow(bundleIdentifier: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        
        let pid = app.processIdentifier
        
        let appElement = AXUIElementCreateApplication(pid)
        var mainWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow)
        
        guard result == .success,
              let windowRef = mainWindow,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            // Try getting first window if no main window
            if let firstWindow = globalStandardWindows(for: app).first {
                return firstWindow
            }
            return nil
        }
        
        return (windowRef as! AXUIElement)
    }

    /// Activate an app and show its main window
    static func activateAndShowMainWindow(bundleIdentifier: String) -> Bool {
        // First, activate the app
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            Logger.log("WindowManager: App \(bundleIdentifier) is not running, cannot activate")
            return false
        }
        defer { invalidateWindowQueryCache(bundleIdentifier: bundleIdentifier) }
        
        _ = activate(app)
        
        // Let activation settle briefly, then re-assert the main window without the older
        // extra latency that used to mask app-click coordination delays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            if let mainWindow = getMainWindow(bundleIdentifier: bundleIdentifier) {
                var position: CFTypeRef?
                if AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &position) == .success {
                    // Window exists, try to bring it forward
                    let frontmost: CFBoolean = kCFBooleanTrue
                    AXUIElementSetAttributeValue(mainWindow, kAXFrontmostAttribute as CFString, frontmost)
                }
            }
        }
        
        Logger.debug("WindowManager: Activated app \(bundleIdentifier) and showing main window")
        return true
    }
    
    
    
    
    





    private static func copyAXAttributeValue(element: AXUIElement,
                                             attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }


    private static func rawAppWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let rawWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return rawWindows
    }

    private static func globalStandardWindows(for app: NSRunningApplication) -> [AXUIElement] {
        rawAppWindows(for: app).filter { window in
            shouldIncludeGlobalStandardWindow(window, bundleIdentifier: app.bundleIdentifier)
        }
    }


    private static func windowCandidates(for app: NSRunningApplication,
                                         includeSpaceIDs: Bool = true,
                                         rawCGEntries: [[String: AnyObject]]? = nil) -> [WindowCandidate] {
        let cgEntries = cgWindowEntries(for: app.processIdentifier,
                                        in: rawCGEntries ?? allCGWindowEntries())
        var usedWindowIDs = Set<CGWindowID>()

        return rawAppWindows(for: app).compactMap { window in
            makeWindowCandidate(window,
                                cgEntries: cgEntries,
                                includeSpaceIDs: includeSpaceIDs,
                                usedWindowIDs: &usedWindowIDs)
        }
    }

    private static func shouldIncludeGlobalStandardCandidate(_ candidate: WindowCandidate,
                                                             bundleIdentifier: String?) -> Bool {
        guard shouldIncludeGlobalStandardWindow(candidate.axWindow, bundleIdentifier: bundleIdentifier) else {
            return false
        }

        guard passesGeneralCandidateValidation(candidate) else {
            return false
        }

        return true
    }

    private static func relaxedAppExposeAXWindowCount(from candidates: [WindowCandidate]) -> Int {
        let count = candidates.filter { candidate in
            if candidate.isMinimized {
                return false
            }

            if !passesGeneralCandidateValidation(candidate) {
                return false
            }

            return true
        }.count

        return count >= 2 ? count : 0
    }


    private static func shouldIncludeGlobalStandardWindow(_ window: AXUIElement,
                                                          bundleIdentifier: String?) -> Bool {
        guard roleIsWindow(window) else {
            return false
        }

        guard isStandardSubrole(stringAttribute(window, attribute: kAXSubroleAttribute as CFString)) else {
            return false
        }

        if bundleIdentifier == braveBundleIdentifier, isLikelyBraveAuxiliaryWindow(window) {
            let title = stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "nil"
            let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? "nil"
            let identifier = stringAttribute(window, attribute: "AXIdentifier" as CFString) ?? "nil"
            Logger.debug("WindowManager: Excluding Brave auxiliary window title=\(title) subrole=\(subrole) identifier=\(identifier)")
            return false
        }

        return true
    }


    private static func isFullScreenWindow(_ candidate: WindowCandidate,
                                           fullScreenSpaceIDs: Set<Int>) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(candidate.axWindow, "AXFullScreen" as CFString, &value) == .success,
           (value as? Bool) == true {
            return true
        }
        guard !fullScreenSpaceIDs.isEmpty, let windowID = candidate.cgWindowID else { return false }
        return !WindowSpacePrivateApis.spaces(for: windowID).isDisjoint(with: fullScreenSpaceIDs)
    }

    private static func isLikelyBraveAuxiliaryWindow(_ window: AXUIElement) -> Bool {
        let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString) ?? ""
        if braveAuxiliarySubroles.contains(subrole) {
            return true
        }

        let textFields = [
            stringAttribute(window, attribute: kAXTitleAttribute as CFString),
            stringAttribute(window, attribute: "AXIdentifier" as CFString),
            stringAttribute(window, attribute: kAXDescriptionAttribute as CFString)
        ]
        let containsSidebarMarker = textFields
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("sidebar") || value.contains("side panel") || value.contains("sidepanel") || value.contains("vertical tabs")
            }
        guard containsSidebarMarker else {
            return false
        }

        let hasTrafficLightControls =
            hasElementAttribute(window, attribute: kAXCloseButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXMinimizeButtonAttribute as CFString) ||
            hasElementAttribute(window, attribute: kAXZoomButtonAttribute as CFString)
        return !hasTrafficLightControls
    }

    private static func roleIsWindow(_ window: AXUIElement) -> Bool {
        guard let role = stringAttribute(window, attribute: kAXRoleAttribute as CFString) else {
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

    private static func passesGeneralCandidateValidation(_ candidate: WindowCandidate) -> Bool {
        if let layer = candidate.layer, layer < 0 {
            return false
        }

        if let alpha = candidate.alpha, alpha <= 0.01 {
            return false
        }

        let size = candidate.bounds?.size ?? sizeAttribute(candidate.axWindow)
        guard let size else {
            return true
        }

        if size == .zero {
            return false
        }

        return size.width >= minimumCandidateWindowSize.width
            && size.height >= minimumCandidateWindowSize.height
    }

    private static func makeWindowCandidate(_ window: AXUIElement,
                                            cgEntries: [[String: AnyObject]],
                                            includeSpaceIDs: Bool,
                                            usedWindowIDs: inout Set<CGWindowID>) -> WindowCandidate? {
        let resolvedWindowID = resolveCGWindowID(for: window,
                                                 cgEntries: cgEntries,
                                                 usedWindowIDs: &usedWindowIDs)
        let matchingEntry = resolvedWindowID.flatMap { cgEntry(for: $0, in: cgEntries) }
        let bounds = matchingEntry.flatMap(boundsFromCGEntry)
        let layer = matchingEntry.flatMap { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue }
        let alpha = matchingEntry.flatMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue }
        let isOnScreen = matchingEntry.flatMap { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue } ?? false
        let subrole = stringAttribute(window, attribute: kAXSubroleAttribute as CFString)
        let isMinimized = isWindowMinimized(window)
        let spaceIDs = includeSpaceIDs
            ? (resolvedWindowID.map(WindowSpacePrivateApis.spaces(for:)) ?? [])
            : []

        return WindowCandidate(axWindow: window,
                               cgWindowID: resolvedWindowID,
                               bounds: bounds,
                               layer: layer,
                               alpha: alpha,
                               isOnScreen: isOnScreen,
                               subrole: subrole,
                               spaceIDs: spaceIDs,
                               isMinimized: isMinimized)
    }

    private static func cgWindowEntries(for pid: pid_t) -> [[String: AnyObject]] {
        cgWindowEntries(for: pid, in: allCGWindowEntries())
    }

    private static func cgWindowEntries(for pid: pid_t,
                                        in entries: [[String: AnyObject]]) -> [[String: AnyObject]] {
        entries.filter { entry in
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return ownerPID == pid
        }
    }

    private static func cgsCrossSpaceStandardWindowCount(for app: NSRunningApplication,
                                                         excludingAXWindowIDs axWindowIDs: Set<CGWindowID>,
                                                         rawCGEntries: [[String: AnyObject]]? = nil,
                                                         stopAt: Int? = nil,
                                                         phases: inout AppExposeCountPhaseTimings) -> Int {
        var phaseStartedAt = CFAbsoluteTimeGetCurrent()
        let managedSpaceIDs = WindowSpacePrivateApis.managedSpaceIDs()
        phases.managedSpacesMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)
        guard !managedSpaceIDs.isEmpty else {
            return 0
        }

        phaseStartedAt = CFAbsoluteTimeGetCurrent()
        let cgsWindowIDs = WindowSpacePrivateApis.windowIDs(in: managedSpaceIDs)
        phases.cgsWindowIDsMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)
        guard !cgsWindowIDs.isEmpty else {
            return 0
        }

        phaseStartedAt = CFAbsoluteTimeGetCurrent()
        let targetPIDs = relatedProcessIDs(for: app)
        phases.relatedPIDsMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)

        phaseStartedAt = CFAbsoluteTimeGetCurrent()
        let rawCGEntries = rawCGEntries ?? allCGWindowEntries()
        let entriesByWindowID = Dictionary(uniqueKeysWithValues: cgWindowEntries(for: targetPIDs, in: rawCGEntries).compactMap { entry -> (CGWindowID, [String: AnyObject])? in
            let windowID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else { return nil }
            return (windowID, entry)
        })
        phases.cgEntriesMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)

        var activeSpaceIDs: Set<Int>?
        func resolvedActiveSpaceIDs() -> Set<Int> {
            if let activeSpaceIDs {
                return activeSpaceIDs
            }
            let phaseStartedAt = CFAbsoluteTimeGetCurrent()
            let resolved = currentActiveSpaceIDs(from: rawCGEntries)
            phases.activeSpacesMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)
            activeSpaceIDs = resolved
            return resolved
        }

        let axCountInManagedSpaces = axWindowIDs.filter { windowID in
            cgsWindowIDs.contains(windowID)
        }.count
        var count = axCountInManagedSpaces
        if let stopAt, count >= stopAt {
            return stopAt
        }

        phaseStartedAt = CFAbsoluteTimeGetCurrent()
        for windowID in cgsWindowIDs.subtracting(axWindowIDs) {
            guard shouldIncludeCGSCrossSpaceWindow(windowID: windowID,
                                                   entry: entriesByWindowID[windowID],
                                                   targetPIDs: targetPIDs,
                                                   activeSpaceIDs: resolvedActiveSpaceIDs) else {
                continue
            }
            count += 1
            if let stopAt, count >= stopAt {
                phases.cgsFilterMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)
                return stopAt
            }
        }

        phases.cgsFilterMs = Int((CFAbsoluteTimeGetCurrent() - phaseStartedAt) * 1000)
        return count
    }

    private static func shouldIncludeCGSCrossSpaceWindow(windowID: CGWindowID,
                                                         entry: [String: AnyObject]?,
                                                         targetPIDs: Set<pid_t>,
                                                         activeSpaceIDs: () -> Set<Int>) -> Bool {
        guard let ownerPID = WindowSpacePrivateApis.ownerPID(for: windowID),
              targetPIDs.contains(ownerPID) else {
            return false
        }

        if let entry {
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard layer == 0 else {
                return false
            }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.01 else {
                return false
            }

            if let bounds = boundsFromCGEntry(entry) {
                guard bounds.size.width >= minimumCandidateWindowSize.width,
                      bounds.size.height >= minimumCandidateWindowSize.height else {
                    return false
                }
            }
        } else {
            let spaceIDs = WindowSpacePrivateApis.spaces(for: windowID)
            guard !spaceIDs.isEmpty, spaceIDs.isDisjoint(with: activeSpaceIDs()) else {
                return false
            }
        }

        return true
    }

    private static func relatedProcessIDs(for app: NSRunningApplication) -> Set<pid_t> {
        guard let bundleIdentifier = app.bundleIdentifier else {
            return [app.processIdentifier]
        }

        return cachedWindowQueryValue(for: bundleIdentifier,
                                      cache: &relatedProcessIDsCache,
                                      ttl: relatedProcessIDsCacheTTL) {
            uncachedRelatedProcessIDs(for: app)
        }
    }

    private static func uncachedRelatedProcessIDs(for app: NSRunningApplication) -> Set<pid_t> {
        var pids: Set<pid_t> = [app.processIdentifier]
        guard let appBundlePath = app.bundleURL?.standardizedFileURL.path else {
            return pids
        }

        for runningApp in NSWorkspace.shared.runningApplications {
            guard runningApp.processIdentifier != app.processIdentifier,
                  let bundlePath = runningApp.bundleURL?.standardizedFileURL.path else {
                continue
            }

            if bundlePath == appBundlePath || bundlePath.hasPrefix(appBundlePath + "/") {
                pids.insert(runningApp.processIdentifier)
            }
        }

        return pids
    }

    private static func allCGWindowEntries() -> [[String: AnyObject]] {
        CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] ?? []
    }

    private static func cgWindowEntries(for pids: Set<pid_t>) -> [[String: AnyObject]] {
        cgWindowEntries(for: pids, in: allCGWindowEntries())
    }

    private static func cgWindowEntries(for pids: Set<pid_t>,
                                        in entries: [[String: AnyObject]]) -> [[String: AnyObject]] {
        entries.filter { entry in
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return pids.contains(ownerPID)
        }
    }

    private static func currentActiveSpaceIDs() -> Set<Int> {
        currentActiveSpaceIDs(from: allCGWindowEntries())
    }

    private static func currentActiveSpaceIDs(from entries: [[String: AnyObject]]) -> Set<Int> {
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

            activeSpaceIDs.formUnion(WindowSpacePrivateApis.spaces(for: windowID))
        }

        return activeSpaceIDs
    }

    private static func resolveCGWindowID(for window: AXUIElement,
                                          cgEntries: [[String: AnyObject]],
                                          usedWindowIDs: inout Set<CGWindowID>) -> CGWindowID? {
        if let directWindowID = WindowSpacePrivateApis.windowID(for: window), directWindowID != 0 {
            usedWindowIDs.insert(directWindowID)
            return directWindowID
        }

        let fallbackWindowID = mapAXWindowToCGWindowID(window,
                                                       cgEntries: cgEntries,
                                                       excluding: usedWindowIDs)
        if let fallbackWindowID {
            usedWindowIDs.insert(fallbackWindowID)
        }
        return fallbackWindowID
    }

    private static func mapAXWindowToCGWindowID(_ window: AXUIElement,
                                                cgEntries: [[String: AnyObject]],
                                                excluding usedWindowIDs: Set<CGWindowID>) -> CGWindowID? {
        let axTitle = (stringAttribute(window, attribute: kAXTitleAttribute as CFString) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let axPosition = pointAttribute(window, attribute: kAXPositionAttribute as CFString)
        let axSize = sizeAttribute(window)
        let tolerance: CGFloat = 2.0

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
               let positionMatch = abs(candidateBounds.origin.x - axPosition.x) <= tolerance
                   && abs(candidateBounds.origin.y - axPosition.y) <= tolerance
               let sizeMatch = abs(candidateBounds.size.width - axSize.width) <= tolerance
                   && abs(candidateBounds.size.height - axSize.height) <= tolerance
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

    private static func cgEntry(for windowID: CGWindowID,
                                in cgEntries: [[String: AnyObject]]) -> [String: AnyObject]? {
        cgEntries.first { entry in
            let candidateID = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return candidateID == windowID
        }
    }

    nonisolated private static func boundsFromCGEntry(_ entry: [String: AnyObject]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: AnyObject] else {
            return nil
        }

        let x = CGFloat((bounds["X"] as? NSNumber)?.doubleValue ?? .nan)
        let y = CGFloat((bounds["Y"] as? NSNumber)?.doubleValue ?? .nan)
        let width = CGFloat((bounds["Width"] as? NSNumber)?.doubleValue ?? .nan)
        let height = CGFloat((bounds["Height"] as? NSNumber)?.doubleValue ?? .nan)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
              let isMinimized = minimizedValue as? Bool else {
            return false
        }
        return isMinimized
    }


    private static func pointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID(),
              AXValueGetType(axValue as! AXValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID(),
              AXValueGetType(axValue as! AXValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func hasElementAttribute(_ element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return false
        }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

}
