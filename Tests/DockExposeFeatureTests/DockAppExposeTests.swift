import Testing
@testable import DockExposeFeature

@Test func appExposeNeedsMoreThanOneWindow() {
    #expect(!DockAppExposeFeature.shouldShowAppExpose(windowCount: 0))
    #expect(!DockAppExposeFeature.shouldShowAppExpose(windowCount: 1))
    #expect(DockAppExposeFeature.shouldShowAppExpose(windowCount: 2))
    #expect(DockAppExposeFeature.shouldShowAppExpose(windowCount: 5))
}
