import Foundation
import Testing
@testable import SimpleMacFixesCore

@Test func permissionRestartResumesIncompleteSetup() {
    let name = "KeyControl.SetupTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let progress = SetupProgress(defaults: defaults)
    progress.step = 1
    defaults.set(true, forKey: "didRequestAccessibility")
    defaults.set(true, forKey: "didRequestInputMonitoring")
    defaults.set(true, forKey: "didRequestSystemAudio")
    let restarted = SetupProgress(defaults: defaults)
    #expect(!restarted.isComplete)
    #expect(restarted.step == 1)
    restarted.step = 2
    #expect(!SetupProgress(defaults: defaults).isComplete)
    restarted.finish()
    #expect(SetupProgress(defaults: defaults).isComplete)
    restarted.beginAgain()
    #expect(!restarted.isComplete)
    #expect(restarted.step == 0)
}
