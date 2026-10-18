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
    // Beside a side Dock, past a bubble that grows with the name.
    let short = DockPreviewPanel.nameBubbleClearance(for: "Mail", edge: "left")
    let long = DockPreviewPanel.nameBubbleClearance(for: "Brave Browser Nightly", edge: "left")
    #expect(long > short && short > 44)
    let left = CGRect(x: 10, y: 400, width: 48, height: 48)
    #expect(DockPreviewPanel.origin(for: size, beside: left, edge: "left", clearance: long, within: screen).x == 58 + long)
    let right = CGRect(x: 1440, y: 400, width: 48, height: 48)
    #expect(DockPreviewPanel.origin(for: size, beside: right, edge: "right", clearance: short, within: screen).x
        == 1440 - short - 440)
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
