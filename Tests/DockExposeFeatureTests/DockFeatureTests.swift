import Testing
@testable import DockExposeFeature

import CoreGraphics

/// Icon frames and label positions read from the macOS 27 Dock on screen (2x display).
@Test @MainActor func previewCoversTheDocksNameLabelExactly() {
    func edge(_ icon: CGRect, _ dock: String, _ magnified: Bool) -> CGFloat {
        DockPreviewPanel.labelEdge(beside: icon, edge: dock, magnified: magnified, scale: 2)
    }
    // Bottom Dock: the label's arrow tip.
    #expect(edge(CGRect(x: 519.7, y: 931, width: 34, height: 46), "bottom", false) == 929)
    #expect(edge(CGRect(x: 347.05, y: 902.16, width: 58.84, height: 74.84), "bottom", false) == 900.5)
    #expect(edge(CGRect(x: 419.7, y: 867, width: 98, height: 110), "bottom", true) == 874)
    #expect(edge(CGRect(x: 438, y: 867.7, width: 97.3, height: 109.3), "bottom", true) == 875)
    #expect(edge(CGRect(x: 282.9, y: 893, width: 68, height: 84), "bottom", true) == 901)
    // Side Docks: the label's end nearest the icon.
    #expect(edge(CGRect(x: 5, y: 271.2, width: 46, height: 34), "left", false) == 56.5)
    #expect(edge(CGRect(x: 5, y: 155.2, width: 142, height: 130), "left", true) == 147.5)
    #expect(edge(CGRect(x: 5, y: 189.5, width: 109.3, height: 97.3), "left", true) == 114.5)
    #expect(edge(CGRect(x: 1459, y: 271.2, width: 46, height: 34), "right", false) == 1455.5)
    #expect(edge(CGRect(x: 1395.7, y: 189.5, width: 109.3, height: 97.3), "right", true) == 1397.5)
}

@Test @MainActor func previewSitsOnTheLabelCentredOnTheIconAndStaysOnScreen() {
    let screen = CGRect(x: 8, y: 8, width: 1496, height: 966)
    let size = CGSize(width: 440, height: 200)
    let bottom = CGRect(x: 519.7, y: 931, width: 34, height: 46)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: bottom, edge: "bottom", magnified: false, scale: 2, within: screen)
        == CGRect(x: 316.5, y: 729, width: 440, height: 200))
    let left = CGRect(x: 5, y: 271.2, width: 46, height: 34)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: left, edge: "left", magnified: false, scale: 2, within: screen)
        == CGRect(x: 56.5, y: 188, width: 440, height: 200))
    let right = CGRect(x: 1459, y: 271.2, width: 46, height: 34)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: right, edge: "right", magnified: false, scale: 2, within: screen)
        == CGRect(x: 1015.5, y: 188, width: 440, height: 200))
    // Near a screen corner it moves along the Dock to stay on screen.
    let corner = CGRect(x: 5, y: 900, width: 46, height: 34)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: corner, edge: "left", magnified: false, scale: 2, within: screen).maxY
        == 974)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: CGRect(x: 10, y: 931, width: 34, height: 46), edge: "bottom",
                                        magnified: false, scale: 2, within: screen).minX == 8)
}

@Test @MainActor func besideASideDockTheFirstCardIsCentredOnTheIcon() {
    let screen = CGRect(x: 8, y: 41, width: 1496, height: 933)
    let size = CGSize(width: 236, height: 362)
    let icon = CGRect(x: 5, y: 400, width: 46, height: 34)
    // The first card's centre, 90.5 points down the glass, sits on the icon's centre.
    #expect(DockPreviewPanel.glassFrame(for: size, beside: icon, edge: "left", magnified: false, scale: 2, within: screen,
                                        firstCardCentre: 90.5).minY == 417 - 90.5)
    // Near the top of the screen it stays below the menu bar.
    let high = CGRect(x: 5, y: 45, width: 46, height: 34)
    #expect(DockPreviewPanel.glassFrame(for: size, beside: high, edge: "left", magnified: false, scale: 2, within: screen,
                                        firstCardCentre: 90.5).minY == 41)
}

@Test func aWindowCardShowsTheWindowsOwnName() {
    // An app that names every window after itself over accessibility.
    #expect(DockWindows.title(accessibility: "Ardia", server: "Personal — youtube.com & 1 Tab", appName: "Ardia")
        == "Personal — youtube.com & 1 Tab")
    #expect(DockWindows.title(accessibility: "Notes.txt", server: "Other", appName: "TextEdit") == "Notes.txt")
    #expect(DockWindows.title(accessibility: "", server: "Inbox", appName: "Mail") == "Inbox")
    // Without Screen Recording the window server gives no name.
    #expect(DockWindows.title(accessibility: "Ardia", server: "", appName: "Ardia") == "Ardia")
    #expect(DockWindows.title(accessibility: nil, server: nil, appName: "Mail") == "")
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

@Test func onlyTheWindowUnderThePointerPlays() {
    let windows = [
        DockWindow(id: 3, processIdentifier: 1, title: "3", place: .here, bounds: .zero),
        DockWindow(id: 7, processIdentifier: 1, title: "7", place: .minimized, bounds: .zero),
    ]
    #expect(LiveWindow.choose(hovered: 3, windows: windows) == 3)
    // No pointer on a card, or the window is not on this desktop: nothing plays.
    #expect(LiveWindow.choose(hovered: nil, windows: windows) == nil)
    #expect(LiveWindow.choose(hovered: 7, windows: windows) == nil)
    // The preview closed.
    #expect(LiveWindow.choose(hovered: 3, windows: []) == nil)
}

@Test func aSlowMoveAlongTheDockIsNotAimingAtThePreview() {
    // Along a bottom Dock with a little drift up: the next icon takes over.
    #expect(!DockPreviewsFeature.isLeavingDock(CGPoint(x: 6, y: -1), edge: "bottom"))
    #expect(!DockPreviewsFeature.isLeavingDock(CGPoint(x: -20, y: -5), edge: "bottom"))
    // Up from the icon to a card, also one 300 points to the side (about 27°).
    #expect(DockPreviewsFeature.isLeavingDock(CGPoint(x: 0, y: -10), edge: "bottom"))
    #expect(DockPreviewsFeature.isLeavingDock(CGPoint(x: 300, y: -150), edge: "bottom"))
    // Toward the screen edge is never toward the preview.
    #expect(!DockPreviewsFeature.isLeavingDock(CGPoint(x: 0, y: 10), edge: "bottom"))
    // Side Docks: away is to the right of a left Dock and to the left of a right one.
    #expect(DockPreviewsFeature.isLeavingDock(CGPoint(x: 20, y: 4), edge: "left"))
    #expect(!DockPreviewsFeature.isLeavingDock(CGPoint(x: 1, y: 20), edge: "left"))
    #expect(DockPreviewsFeature.isLeavingDock(CGPoint(x: -20, y: -4), edge: "right"))
}

@Test func scrollingOnTheIconStopsAtTheEndsThenGoesRound() {
    // Inside the list, one window for each step.
    #expect(DockPreviewsFeature.nextSelection(from: 0, steps: 1, count: 3, newScroll: false) == 1)
    // A quick spin stops at the last window, and at the first.
    #expect(DockPreviewsFeature.nextSelection(from: 1, steps: 5, count: 3, newScroll: false) == 2)
    #expect(DockPreviewsFeature.nextSelection(from: 2, steps: 1, count: 3, newScroll: false) == 2)
    #expect(DockPreviewsFeature.nextSelection(from: 0, steps: -1, count: 3, newScroll: false) == 0)
    // A new scroll from an end, after a pause, goes round to the other end.
    #expect(DockPreviewsFeature.nextSelection(from: 2, steps: 1, count: 3, newScroll: true) == 0)
    #expect(DockPreviewsFeature.nextSelection(from: 0, steps: -2, count: 3, newScroll: true) == 2)
    // A new scroll that starts inside the list still stops at the end.
    #expect(DockPreviewsFeature.nextSelection(from: 1, steps: 4, count: 3, newScroll: true) == 2)
}
