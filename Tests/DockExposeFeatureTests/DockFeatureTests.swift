import Testing
@testable import DockExposeFeature

import CoreGraphics

@Test @MainActor func previewSitsPastTheDocksNameBubbleAndStaysOnScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
    let size = CGSize(width: 440, height: 200)
    let icon = CGRect(x: 500, y: 10, width: 48, height: 48)
    let above = DockPreviewPanel.nameBubbleClearance(for: "Safari", edge: "bottom")
    // Above a bottom Dock's name bubble, centred on the icon.
    #expect(DockPreviewPanel.origin(for: size, beside: icon, edge: "bottom", clearance: above, within: screen)
        == CGPoint(x: 304, y: 58 + above))
    // Beside a side Dock, under the name bubble and lined up with its Dock-side end.
    let gap = DockNameBubble.gap, bubble = DockNameBubble.height
    let left = CGRect(x: 10, y: 400, width: 48, height: 48)
    #expect(DockPreviewPanel.origin(for: size, beside: left, edge: "left", clearance: 0, within: screen)
        == CGPoint(x: 58 + gap, y: 424 - bubble / 2 - gap - 200))
    let right = CGRect(x: 1440, y: 400, width: 48, height: 48)
    #expect(DockPreviewPanel.origin(for: size, beside: right, edge: "right", clearance: 0, within: screen).x
        == 1440 - gap - 440)
    // Near the bottom of the screen there's no room under the bubble, so it goes over it.
    let low = CGRect(x: 10, y: 20, width: 48, height: 48)
    #expect(DockPreviewPanel.origin(for: size, beside: low, edge: "left", clearance: 0, within: screen).y
        == 44 + bubble / 2 + gap)
    // An icon near the corner never pushes the preview off screen.
    #expect(DockPreviewPanel.origin(for: size, beside: CGRect(x: 0, y: 10, width: 48, height: 48), edge: "bottom",
                                    clearance: above, within: screen).x == 0)
}

@Test func onlyAPlainOptionClickOpensAFolderInFinder() {
    #expect(DockFolderFinderFeature.isOptionClick([.maskAlternate]))
    #expect(DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskNonCoalesced]))
    #expect(!DockFolderFinderFeature.isOptionClick([]))
    #expect(!DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskCommand]))
    #expect(!DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskShift]))
}

private let previewFrame = CGRect(x: 400, y: 900, width: 500, height: 200)

@Test func movingUpTowardThePreviewKeepsIt() {
    #expect(DockPreviewsFeature.isHeading(from: CGPoint(x: 700, y: 1380), direction: CGPoint(x: 3, y: -20), toward: previewFrame))
}

@Test func movingAlongTheDockOrAwayDoesNotKeepIt() {
    #expect(!DockPreviewsFeature.isHeading(from: CGPoint(x: 700, y: 1380), direction: CGPoint(x: 20, y: 0), toward: previewFrame))
    #expect(!DockPreviewsFeature.isHeading(from: CGPoint(x: 700, y: 1380), direction: CGPoint(x: 0, y: 20), toward: previewFrame))
    // Up, but slanting so far sideways that it passes beside the preview.
    #expect(!DockPreviewsFeature.isHeading(from: CGPoint(x: 700, y: 1380), direction: CGPoint(x: 40, y: -5), toward: previewFrame))
}

@Test func aBarelyMovingPointerDoesNotKeepIt() {
    #expect(!DockPreviewsFeature.isHeading(from: CGPoint(x: 700, y: 1380), direction: CGPoint(x: 0, y: -1), toward: previewFrame))
}

@Test func eachWheelNotchMovesOneWindow() {
    #expect(DockPreviewsFeature.selectionSteps(for: .init(isContinuous: false, delta: -1), carrying: 0).steps == 1)
    #expect(DockPreviewsFeature.selectionSteps(for: .init(isContinuous: false, delta: 3), carrying: 0).steps == -1)
}

@Test func trackpadTravelBuildsUpToAStep() {
    var result = DockPreviewsFeature.selectionSteps(for: .init(isContinuous: true, delta: -20), carrying: 0)
    #expect(result.steps == 0)
    result = DockPreviewsFeature.selectionSteps(for: .init(isContinuous: true, delta: -15), carrying: result.travel)
    #expect(result.steps == 1)
    #expect(result.travel == 5)
}

@Test func turningBackStartsTheTravelAfresh() {
    let result = DockPreviewsFeature.selectionSteps(for: .init(isContinuous: true, delta: 10), carrying: 25)
    #expect(result.steps == 0)
    #expect(result.travel == -10)
}

@Test func openCardsKeepTheirPlacesAndNewWindowsGoLast() {
    func window(_ id: CGWindowID) -> DockWindow {
        DockWindow(id: id, processIdentifier: 1, title: "\(id)", place: .here, bounds: .zero)
    }
    let shown = [window(1), window(2), window(3)]
    // Window 3 came forward, window 2 closed and window 4 opened.
    let kept = DockPreviewsFeature.keepingOrder(of: shown, updatedTo: [window(3), window(4), window(1)])
    #expect(kept.map(\.id) == [1, 3, 4])
}
