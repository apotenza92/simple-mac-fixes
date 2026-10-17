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

@Test func conflictsMatchBetaAndDevBuilds() {
    let running = ["com.lujjjh.LinearMouse", "pzc.Macsimize.beta", "pzc.Macsimizer"]
    #expect(ConflictingApp.conflicts(in: .mouseScrollReversal, runningBundleIdentifiers: running).map(\.name) == ["LinearMouse"])
    #expect(ConflictingApp.conflicts(in: .greenButtonMaximize, runningBundleIdentifiers: running).map(\.name) == ["Macsimize"])
    #expect(ConflictingApp.conflicts(in: .finderCut, runningBundleIdentifiers: running).isEmpty)
}
