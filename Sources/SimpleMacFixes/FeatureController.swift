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
    private let dockAppExpose = DockAppExposeFeature()
    private let dockFolderFinder = DockFolderFinderFeature()
    private var workspaceObservers: [NSObjectProtocol] = []

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
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didLaunchApplicationNotification, let app { self?.quitIfReplaced(app) }
                    self?.objectWillChange.send()
                }
            })
        }
        // The old apps would double up on every fix, including at login if
        // they launch after this one.
        NSWorkspace.shared.runningApplications.forEach(quitIfReplaced)
        apply()
    }

    func stop() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        finderCut.stop()
        mouseScrollReversal.stop()
        greenButtonMaximize.stop()
        dockAppExpose.stop()
        dockFolderFinder.stop()
    }

    private func quitIfReplaced(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, ConflictingApp.isReplaced(id) else { return }
        app.terminate()
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
        sync(.dockAppExpose, running: dockAppExpose.isRunning, trusted: trusted,
             start: dockAppExpose.start, stop: dockAppExpose.stop)
        sync(.dockFolderFinder, running: dockFolderFinder.isRunning, trusted: trusted,
             start: dockFolderFinder.start, stop: dockFolderFinder.stop)
    }

    private func sync(_ feature: Feature, running: Bool, trusted: Bool,
                      start: () -> Bool, stop: () -> Void) {
        let wanted = trusted && isEnabled(feature)
        if wanted, !running { _ = start() }
        if !wanted, running { stop() }
    }
}
