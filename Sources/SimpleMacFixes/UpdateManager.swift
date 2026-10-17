import AppKit
import Combine
import Foundation
import Sparkle
import SimpleMacFixesCore

/// Each release identity stays on its own architecture-specific signed feed.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var schedule: UpdateCheckSchedule = .weekly
    @Published private(set) var isAvailable = false
    private var observations = Set<AnyCancellable>()
    private let scheduleKey = "automaticUpdateCheckSchedule"
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        if let test = UpdateTestSession.current,
           Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == test.expectedBuild {
            test.record("installed-and-relaunched:" + test.expectedBuild)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        guard AppIdentity.releaseBundleIdentifiers.contains(Bundle.main.bundleIdentifier ?? ""),
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        refreshSchedule(automaticChecksEnabled: controller.updater.automaticallyChecksForUpdates)
        if schedule != .never { controller.updater.updateCheckInterval = schedule.interval }
        controller.startUpdater()
        if UpdateTestSession.current != nil {
            controller.updater.automaticallyDownloadsUpdates = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.updater.checkForUpdatesInBackground() }
        } else if schedule == .startup && controller.updater.automaticallyChecksForUpdates {
            // Sparkle recommends checking immediately after startup, before its next run-loop cycle.
            controller.updater.checkForUpdatesInBackground()
        }
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshSchedule(automaticChecksEnabled: $0) }
            .store(in: &observations)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateTestSession.current?.feedURL
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                            immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard UpdateTestSession.current != nil else { return false }
        immediateInstallationBlock()
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        UpdateTestSession.current?.record("error:" + error.localizedDescription)
    }

    private func refreshSchedule(automaticChecksEnabled: Bool) {
        schedule = .resolve(saved: UserDefaults.standard.string(forKey: scheduleKey),
                            bundleIdentifier: Bundle.main.bundleIdentifier,
                            automaticChecksEnabled: automaticChecksEnabled)
    }

    func setSchedule(_ value: UpdateCheckSchedule) {
        guard let controller else { return }
        UserDefaults.standard.set(value.rawValue, forKey: scheduleKey)
        controller.updater.automaticallyChecksForUpdates = value != .never
        if value != .never { controller.updater.updateCheckInterval = value.interval }
        schedule = value
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
