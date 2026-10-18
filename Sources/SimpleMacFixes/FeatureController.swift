import AppKit
import ApplicationServices
import Combine
import DockExposeFeature
import MaximizeFeature
import SimpleMacFixesCore

/// Owns the on/off fixes and keeps each in step with its toggle and with
/// Accessibility access. Keyboard control lives in `AppModel`.
@MainActor
final class FeatureController: ObservableObject {
    private let defaults: UserDefaults
    private let finderCut = FinderCutFeature()
    private let mouseScrollReversal = MouseScrollReversalFeature()
    private let greenButtonMaximize = GreenButtonMaximizeFeature()
    private let dockPreviews = DockPreviewsFeature()
    private let dockFolderFinder = DockFolderFinderFeature()
    private let instantSpaces = InstantSpacesFeature()
    private let instantDock = InstantDockFeature()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningAppsObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Feature.allCases.map {
            ($0.defaultsKey, $0.enabledByDefault)
        }))
    }

    func isEnabled(_ feature: Feature) -> Bool {
        defaults.bool(forKey: feature.defaultsKey)
    }

    func setEnabled(_ feature: Feature, _ enabled: Bool) {
        objectWillChange.send()
        defaults.set(enabled, forKey: feature.defaultsKey)
        if enabled { NSWorkspace.shared.runningApplications.forEach(quitIfReplaced) }
        apply()
    }

    /// Another running utility doing the same job, which would double up or undo it.
    func conflicts(in area: ConflictingApp.Area) -> [ConflictingApp] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return ConflictingApp.conflicts(in: area, runningBundleIdentifiers: running)
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            })
        }
        // The old apps would double up on every fix, including at login if they
        // launch after this one. Launch notifications skip menu-bar-only apps,
        // so watch the running list itself.
        NSWorkspace.shared.runningApplications.forEach(quitIfReplaced)
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let launched = change.newValue ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    launched.forEach { self?.quitIfReplaced($0) }
                    self?.objectWillChange.send()
                }
            }
        }
        apply()
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        runningAppsObservation = nil
        finderCut.stop()
        mouseScrollReversal.stop()
        greenButtonMaximize.stop()
        dockPreviews.stop()
        dockFolderFinder.stop()
        instantSpaces.stop()
        // The Dock goes back to its own settings whenever this app isn't running.
        instantDock.restore()
    }

    private func quitIfReplaced(_ app: NSRunningApplication) {
        quitIfReplaced(app, attempt: 0)
    }

    /// The old apps always; other utilities only while the fix they overlap is on.
    private func shouldQuit(_ bundleIdentifier: String) -> Bool {
        guard let known = ConflictingApp.known.first(where: { $0.matches(bundleIdentifier) }) else { return false }
        return known.isReplaced || Feature.allCases.contains { $0.conflictArea == known.area && isEnabled($0) }
    }

    private func quitIfReplaced(_ app: NSRunningApplication, attempt: Int) {
        guard !app.isTerminated, let id = app.bundleIdentifier, shouldQuit(id) else { return }
        // An app that is still launching ignores the request, so keep asking for a while.
        app.terminate()
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.quitIfReplaced(app, attempt: attempt + 1)
        }
    }

    /// Re-evaluates every feature. `AppModel` calls this when Accessibility access changes.
    func apply() {
        objectWillChange.send()
        let trusted = AXIsProcessTrusted()
        // Each feature starts or stops independently; one failing never blocks another.
        sync(.finderCut, running: finderCut.isRunning, trusted: trusted,
             start: finderCut.start, stop: finderCut.stop)
        sync(.mouseScrollReversal, running: mouseScrollReversal.isRunning, trusted: trusted,
             start: mouseScrollReversal.start, stop: mouseScrollReversal.stop)
        sync(.greenButtonMaximize, running: greenButtonMaximize.isRunning, trusted: trusted,
             start: greenButtonMaximize.start, stop: greenButtonMaximize.stop)
        // Choosing a window on another desktop jumps there instantly.
        dockPreviews.switchToSpace = { InstantSpacesFeature.switchInstantly(toSpace: $0) }
        sync(.dockWindowPreviews, running: dockPreviews.isRunning, trusted: trusted,
             start: dockPreviews.start, stop: dockPreviews.stop)
        sync(.dockFolderFinder, running: dockFolderFinder.isRunning, trusted: trusted,
             start: dockFolderFinder.start, stop: dockFolderFinder.stop)
        sync(.instantSpaces, running: instantSpaces.isRunning, trusted: trusted,
             start: instantSpaces.start, stop: instantSpaces.stop)
        // Needs no permission. Also undoes a previous run's change after a crash.
        sync(.instantDock, running: instantDock.isApplied, trusted: true,
             start: { [instantDock] in instantDock.apply(); return true }, stop: instantDock.restore)
    }

    private func sync(_ feature: Feature, running: Bool, trusted: Bool,
                      start: () -> Bool, stop: () -> Void) {
        let wanted = trusted && isEnabled(feature)
        if wanted, !running { _ = start() }
        if !wanted, running { stop() }
    }
}
