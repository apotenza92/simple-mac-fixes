import Testing
@testable import DockExposeFeature

@Test func appExposeNeedsMoreThanOneWindow() {
    #expect(!DockAppExposeFeature.shouldShowAppExpose(windowCount: 0))
    #expect(!DockAppExposeFeature.shouldShowAppExpose(windowCount: 1))
    #expect(DockAppExposeFeature.shouldShowAppExpose(windowCount: 2))
    #expect(DockAppExposeFeature.shouldShowAppExpose(windowCount: 5))
}

@Test func onlyAPlainOptionClickOpensAFolderInFinder() {
    #expect(DockFolderFinderFeature.isOptionClick([.maskAlternate]))
    #expect(DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskNonCoalesced]))
    #expect(!DockFolderFinderFeature.isOptionClick([]))
    #expect(!DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskCommand]))
    #expect(!DockFolderFinderFeature.isOptionClick([.maskAlternate, .maskShift]))
}
