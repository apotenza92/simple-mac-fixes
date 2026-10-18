import Testing
@testable import SimpleMacFixesCore

@Test func wheelMiceHaveNoGesturePhases() {
    #expect(MouseScrollReversal.source(scrollPhase: 0, momentumPhase: 0) == .wheel)
    #expect(MouseScrollReversal.source(scrollPhase: 1, momentumPhase: 0) == .gesture)
    #expect(MouseScrollReversal.source(scrollPhase: 0, momentumPhase: 2) == .gesture)
}

@Test func onlyWheelsUnderNaturalScrollingAreReversed() {
    #expect(MouseScrollReversal.shouldReverse(source: .wheel, naturalScrollingEnabled: true))
    #expect(!MouseScrollReversal.shouldReverse(source: .wheel, naturalScrollingEnabled: false))
    #expect(!MouseScrollReversal.shouldReverse(source: .gesture, naturalScrollingEnabled: true))
}

@Test func conflictsWarnAboutOtherUtilitiesOnly() {
    let running = ["com.lujjjh.LinearMouse", "pzc.Macsimize.beta", "com.ethanbills.DockDoor"]
    #expect(ConflictingApp.conflicts(in: .mouseScrollReversal, runningBundleIdentifiers: running).map(\.name) == ["LinearMouse"])
    #expect(ConflictingApp.conflicts(in: .dockClicks, runningBundleIdentifiers: running).map(\.name) == ["DockDoor"])
    // Replaced apps are quit, so they never need a warning.
    #expect(ConflictingApp.conflicts(in: .greenButtonMaximize, runningBundleIdentifiers: running).isEmpty)
}

@Test func replacedAppsMatchBetaAndDevBuilds() {
    for id in ["pzc.Macsimize", "pzc.Macsimize.beta", "pzc.Dockmint", "pzc.Docktor", "com.apotenza.KeyControl.beta", "com.apotenza.keycontrol.dev"] {
        #expect(ConflictingApp.isReplaced(id), "\(id)")
    }
    for id in ["pzc.Macsimizer", "com.lujjjh.LinearMouse", "com.apotenza.SimpleMacFixes", "com.ethanbills.DockDoor"] {
        #expect(!ConflictingApp.isReplaced(id), "\(id)")
    }
}

@Test func everyWheelNotchScrollsThreeLinesInItsDirection() {
    #expect(MouseScrollReversal.lines(forNotch: 1, fixedLines: 0.1) == 3)
    // macOS speeds up fast spins; the step stays three lines.
    #expect(MouseScrollReversal.lines(forNotch: 9, fixedLines: 8.7) == 3)
    #expect(MouseScrollReversal.lines(forNotch: -4, fixedLines: -3.5) == -3)
    #expect(MouseScrollReversal.lines(forNotch: -1, fixedLines: 0) == -3)
}
