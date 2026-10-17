import ApplicationServices
import Foundation

enum AppStrings {
    private struct Terms {
        let maximizeVerb: String
        let maximizedAdjective: String
        let behaviorNoun: String
    }

    private static let defaultPreferredLanguagesProvider: @Sendable () -> [String] = {
        let bundleLanguages = Bundle.main.preferredLocalizations
        let systemLanguages = Locale.preferredLanguages
        return bundleLanguages + systemLanguages
    }
    private static let defaultCurrentVersionProvider: @Sendable () -> String = {
        let bundle = Bundle.main
        if let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !shortVersion.isEmpty {
            return shortVersion
        }
        if let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !buildVersion.isEmpty {
            return buildVersion
        }
        return "Unknown"
    }
    private static let defaultOperatingSystemVersionProvider: @Sendable () -> OperatingSystemVersion = {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    nonisolated(unsafe) static var preferredLanguagesProvider: @Sendable () -> [String] = defaultPreferredLanguagesProvider
    nonisolated(unsafe) static var currentVersionProvider: @Sendable () -> String = defaultCurrentVersionProvider
    nonisolated(unsafe) static var operatingSystemVersionProvider: @Sendable () -> OperatingSystemVersion = defaultOperatingSystemVersionProvider

    static func resetPreferredLanguagesProvider() {
        preferredLanguagesProvider = defaultPreferredLanguagesProvider
    }

    static func resetCurrentVersionProvider() {
        currentVersionProvider = defaultCurrentVersionProvider
    }

    static func resetOperatingSystemVersionProvider() {
        operatingSystemVersionProvider = defaultOperatingSystemVersionProvider
    }

    private static var deviceControlPermissionTitle: String {
        operatingSystemVersionProvider().majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    private static var terms: Terms {
        let britishVariants = ["en-GB", "en-AU"]
        let prefersBritish = preferredLanguagesProvider().contains { language in
            britishVariants.contains { language.hasPrefix($0) }
        }
        if prefersBritish {
            return Terms(maximizeVerb: "Maximise", maximizedAdjective: "maximised", behaviorNoun: "Behaviour")
        }
        return Terms(maximizeVerb: "Maximize", maximizedAdjective: "maximized", behaviorNoun: "Behavior")
    }

    static var generalSectionTitle: String { "General" }
    static var permissionsSectionTitle: String { "Permissions" }
    static var updatesSectionTitle: String { "Updates" }
    static var behaviorSectionTitle: String { terms.behaviorNoun }
    static var greenButtonBehaviorSectionTitle: String { "Green Button \(terms.behaviorNoun)" }

    static var showMenuBarIcon: String { "Show menu bar icon" }
    static var showSettingsOnStartup: String { "Show settings on startup" }
    static func startAtLogin(appName: String) -> String { "Start \(appName) at login" }
    static var restartButtonTitle: String { "Restart" }
    static var quitButtonTitle: String { "Quit" }
    static var aboutButtonTitle: String { "About" }
    static func openGitHubHelp(appName: String) -> String { "Open \(appName) on GitHub" }

    static var accessibilityButtonTitle: String { deviceControlPermissionTitle }
    static var inputMonitoringButtonTitle: String { "Input Monitoring" }
    static var openSettingsButtonTitle: String { "Open Settings" }

    static var checkForUpdatesButtonTitle: String { "Check for Updates" }
    static var installUpdateButtonTitle: String { "Install Update…" }
    static var checkFrequencyLabel: String { "Check frequency" }
    static var checkFrequencyCompactLabel: String { "Check" }
    static var greenButtonClickLabel: String { "Green button click" }

    static var settingsMenuTitle: String { "Settings…" }
    static var maximizeAllMenuTitle: String { "\(terms.maximizeVerb) All" }
    static var restoreAllMenuTitle: String { "Restore All" }
    static func quitMenuTitle(appName: String) -> String { "Quit \(appName)" }
    static var appAccessibilityLabel: String { "Macsimize" }

    static var maximizeModeTitle: String { terms.maximizeVerb }
    static var fullScreenModeTitle: String { "Full Screen" }
    static var optionClickPrefix: String { "⌥ Option-click" }
    static var maximizeModeHelp: String {
        "Option-click enters \(fullScreenModeTitle)."
    }
    static var fullScreenModeHelp: String {
        "Option-click \(maximizeModeTitle)s."
    }

    static var updateFrequencyNever: String { "Never" }
    static var updateFrequencyStartup: String { "On Startup" }
    static var updateFrequencyHourly: String { "Every Hour" }
    static var updateFrequencySixHours: String { "Every 6 Hours" }
    static var updateFrequencyTwelveHours: String { "Every 12 Hours" }
    static var updateFrequencyDaily: String { "Daily" }
    static var updateFrequencyWeekly: String { "Weekly" }

    static var permissionSummaryAccessibilityRequired: String { "\(deviceControlPermissionTitle) required" }
    static var permissionSummaryInputMonitoringRequired: String { "Input Monitoring required" }
    static var permissionSummaryReady: String { "Ready" }
    static var permissionSummaryWaitingForEventTap: String { "Waiting for event tap" }
    static var permissionRequiredLabel: String { "Required" }
    static var permissionAccessibilityWhyNeeded: String {
        "Inspect windows and trigger window actions."
    }
    static var permissionInputMonitoringWhyNeeded: String {
        "Intercept green button clicks."
    }
    static var permissionDetailAccessibilityRequired: String {
        "Grant access in System Settings > Privacy & Security > \(deviceControlPermissionTitle). Until then, Macsimize cannot intercept the green button, so macOS will keep using its normal \(terms.behaviorNoun.lowercased())."
    }
    static var permissionDetailInputMonitoringRequired: String {
        "Grant Input Monitoring access in System Settings > Privacy & Security > Input Monitoring. Until then, Macsimize cannot intercept the green button, so macOS will keep using its normal \(terms.behaviorNoun.lowercased())."
    }
    static var permissionDetailSecureEventInput: String {
        "Secure Event Input is active. Event interception may be limited until the blocking app stops using secure input, so native green-button behavior may still slip through."
    }
    static var permissionDetailEventTapInactive: String {
        "Permissions are granted, but the event tap is not running yet. Macsimize is not active until the status changes to Ready."
    }
    static func permissionDetailInterceptingClicks(appName: String) -> String {
        "\(appName) is active and intercepting green-button clicks."
    }
    static var inactiveInterceptionWarning: String {
        "While this is inactive, clicking the green button may still trigger native macOS full screen."
    }

    static func settingsWindowTitle(appName: String) -> String { "\(appName) Settings" }

    static var updateCheckingStatusMessage: String { "Checking for updates..." }
    static var updateCheckSlowStatusMessage: String { "Update check is taking longer than expected." }
    static var updateUpToDateStatusMessage: String { "Up to date." }
    static var updateCheckFailedStatusMessage: String { "Unable to check for updates." }
    static var updatesDisabledAutomatedMode: String { "Updates disabled in automated mode." }
    static var updatesDisabledDevelopmentBuild: String { "Updates disabled in development builds." }
    static var updatesUnavailableIncompleteRuntime: String { "Updates unavailable: incomplete Sparkle runtime in app bundle." }
    static var currentVersionStatusMessage: String { "Current version: \(currentVersionProvider())" }
    static func updateAvailable(version: String) -> String { "Update available: \(version)" }

    static var diagnosticsSnapshotSkippedNoFrontmostApp: String { "Diagnostics snapshot skipped: no frontmost app." }
    static func diagnosticsSnapshotNoFocusedWindow(appName: String) -> String {
        "Diagnostics snapshot: no focused window for \(appName)."
    }
    static var unknownLabel: String { "Unknown" }
    static var untitledLabel: String { "Untitled" }
    static var unknownAppLabel: String { "Unknown App" }

    static var eventTapCreationFailed: String { "Failed to create the event tap." }
    static var eventTapUnavailableFailureReason: String {
        "Unable to create the event tap. Input Monitoring may also be required when interception is enabled."
    }
    static var eventTapReenabledMessage: String { "Event tap was temporarily disabled and then re-enabled." }
    static var eventTapReplayOriginalSequence: String { "Window action failed after intercept; replaying the original mouse sequence." }
    static var eventTapSwallowNativeSequence: String { "Window action failed after intercept; swallowing the click to avoid unexpected native full-screen behavior." }

    static var greenButtonDragFlushMessage: String { "Intercepted green-button press became a drag; flushing buffered native events." }
    static var greenButtonHoldFlushMessage: String { "Intercepted green-button press became a hold; flushing buffered native events." }
    static var greenButtonThresholdFlushMessage: String {
        "Intercepted green-button press exceeded clean-click thresholds; flushing buffered native events."
    }
    static var greenButtonFullScreenPassThroughMessage: String {
        "Window is already in native full screen; passing the green-button click through to macOS."
    }

    static var actionEngineFullScreenPassThrough: String { "Allowing standard macOS full-screen \(terms.behaviorNoun.lowercased())." }
    static var actionEngineFullScreenTriggered: String { "Triggered native macOS full screen via AXFullScreen on the window." }
    static var actionEngineFullScreenActionUnavailable: String { "Green button does not expose AXPress for native full screen." }
    static func actionEngineFullScreenAttributeFailed(code: AXError.RawValue) -> String {
        "AXFullScreen on the window failed with \(code)."
    }
    static func actionEngineFullScreenActionFailed(code: AXError.RawValue) -> String {
        "AXPress on the green button failed with \(code)."
    }
    static var actionEngineWindowNotResizable: String { "Window does not appear to be resizable." }

    static var maximizeWindowFrameUnavailable: String { "Window frame unavailable." }
    static var maximizeWindowSizeNotSettable: String { "Window size is not settable." }
    static var maximizeTargetDisplayUnavailable: String { "Unable to determine a target display." }
    static var maximizePositionNotSettable: String { "AXPosition is not settable for this window; resized only." }
    static var maximizePostApplyFrameDiffers: String { "Post-apply frame differs from the requested destination." }
    static var maximizeRestoredPreviousFrame: String { "Restored the previously stored frame." }
    static var maximizeRestoreExactFrame: String { "Restore destination matched the stored frame." }
    static var maximizeRestoreClampedToVisibleFrame: String { "Restore destination was clamped to the visible frame." }

    static func maximizePositionSetFailed(code: AXError.RawValue) -> String {
        "AXPosition set failed with \(code)."
    }

    static func maximizeSizeSetFailed(code: AXError.RawValue) -> String {
        "AXSize set failed with \(code)."
    }

    static var maximizeAllNoEligibleWindows: String { "No eligible current-Space windows were found for batch maximize." }
    static func maximizeAllFinished(processedCount: Int, skippedCount: Int) -> String {
        "Batch \(terms.maximizeVerb.lowercased()) finished: processed=\(processedCount) skipped=\(skippedCount)"
    }
    static func maximizeAllTimingSummary(
        appCount: Int,
        candidateCount: Int,
        eligibleCount: Int,
        cgEntryCount: Int,
        activeSpaceCount: Int,
        resolvedWindowIDCount: Int,
        spaceResolvedCandidateCount: Int,
        enumerationMs: Double,
        firstActionMs: Double?,
        actionMs: Double,
        averageWindowMs: Double,
        slowestWindowMs: Double,
        totalMs: Double
    ) -> String {
        batchActionTimingSummary(
            label: "Batch \(terms.maximizeVerb.lowercased())",
            appCount: appCount,
            candidateCount: candidateCount,
            eligibleCount: eligibleCount,
            cgEntryCount: cgEntryCount,
            activeSpaceCount: activeSpaceCount,
            resolvedWindowIDCount: resolvedWindowIDCount,
            spaceResolvedCandidateCount: spaceResolvedCandidateCount,
            enumerationMs: enumerationMs,
            firstActionMs: firstActionMs,
            actionMs: actionMs,
            averageWindowMs: averageWindowMs,
            slowestWindowMs: slowestWindowMs,
            totalMs: totalMs
        )
    }
    static func maximizeAllWindowSkipped(reason: String, identifier: String) -> String {
        "Batch \(terms.maximizeVerb.lowercased()) skipped \(identifier): \(reason)"
    }
    static func maximizeAllSkipSummary(_ summary: String) -> String {
        "Batch \(terms.maximizeVerb.lowercased()) skip summary: \(summary)"
    }
    static var maximizeAllSkipReasonCurrentSpaceFilter: String { "current-Space filter" }
    static var maximizeAllSkipReasonNotResizableOrSettable: String { "window not resizable or settable" }

    static var restoreAllNoEligibleWindows: String { "No restorable current-Space windows were found." }
    static func restoreAllFinished(processedCount: Int, skippedCount: Int) -> String {
        "Batch restore finished: processed=\(processedCount) skipped=\(skippedCount)"
    }
    static func restoreAllTimingSummary(
        appCount: Int,
        candidateCount: Int,
        eligibleCount: Int,
        cgEntryCount: Int,
        activeSpaceCount: Int,
        resolvedWindowIDCount: Int,
        spaceResolvedCandidateCount: Int,
        enumerationMs: Double,
        firstActionMs: Double?,
        actionMs: Double,
        averageWindowMs: Double,
        slowestWindowMs: Double,
        totalMs: Double
    ) -> String {
        batchActionTimingSummary(
            label: "Batch restore",
            appCount: appCount,
            candidateCount: candidateCount,
            eligibleCount: eligibleCount,
            cgEntryCount: cgEntryCount,
            activeSpaceCount: activeSpaceCount,
            resolvedWindowIDCount: resolvedWindowIDCount,
            spaceResolvedCandidateCount: spaceResolvedCandidateCount,
            enumerationMs: enumerationMs,
            firstActionMs: firstActionMs,
            actionMs: actionMs,
            averageWindowMs: averageWindowMs,
            slowestWindowMs: slowestWindowMs,
            totalMs: totalMs
        )
    }
    static func restoreAllWindowSkipped(reason: String, identifier: String) -> String {
        "Batch restore skipped \(identifier): \(reason)"
    }
    static func restoreAllSkipSummary(_ summary: String) -> String {
        "Batch restore skip summary: \(summary)"
    }
    static var restoreAllSkipReasonNotManagedMaximized: String { "window is not in a Macsimize-managed maximized state" }

    static var titleBarDoubleClickCaptured: String { "Captured titlebar double-click; routing to deterministic maximize." }
    static var titleBarDoubleClickIgnored: String { "Titlebar double-click did not resolve to an eligible window." }
    static var titleBarDragRestoreTriggered: String { "Triggered drag-restore for a Macsimize-managed maximized window." }
    static var titleBarDragRestoreSkipped: String { "Titlebar drag exceeded threshold, but the window was no longer in a Macsimize-managed maximized state." }
    static func relaunchFailed(errorDescription: String) -> String { "Failed to relaunch app: \(errorDescription)" }

    private static func batchActionTimingSummary(
        label: String,
        appCount: Int,
        candidateCount: Int,
        eligibleCount: Int,
        cgEntryCount: Int,
        activeSpaceCount: Int,
        resolvedWindowIDCount: Int,
        spaceResolvedCandidateCount: Int,
        enumerationMs: Double,
        firstActionMs: Double?,
        actionMs: Double,
        averageWindowMs: Double,
        slowestWindowMs: Double,
        totalMs: Double
    ) -> String {
        let firstActionComponent = firstActionMs.map { formatMilliseconds($0) } ?? "n/a"
        return "\(label) timing: apps=\(appCount) candidates=\(candidateCount) eligible=\(eligibleCount) cgEntries=\(cgEntryCount) activeSpaces=\(activeSpaceCount) resolvedWindowIDs=\(resolvedWindowIDCount) spaceResolved=\(spaceResolvedCandidateCount) enumerationMs=\(formatMilliseconds(enumerationMs)) firstActionMs=\(firstActionComponent) actionMs=\(formatMilliseconds(actionMs)) averageWindowMs=\(formatMilliseconds(averageWindowMs)) slowestWindowMs=\(formatMilliseconds(slowestWindowMs)) totalMs=\(formatMilliseconds(totalMs))"
    }

    private static func formatMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}
