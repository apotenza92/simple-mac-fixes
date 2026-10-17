import Testing
@testable import SimpleMacFixesCore

@Test func commandOnlyXAndVAreShortcuts() {
    #expect(FinderCutTracker.shortcut(characters: "x", commandOnly: true) == .cut)
    #expect(FinderCutTracker.shortcut(characters: "V", commandOnly: true) == .paste)
    #expect(FinderCutTracker.shortcut(characters: "c", commandOnly: true) == .other)
    #expect(FinderCutTracker.shortcut(characters: "x", commandOnly: false) == .other)
    #expect(FinderCutTracker.shortcut(characters: nil, commandOnly: true) == .other)
}

@Test func cutThenPasteMovesFiles() {
    var tracker = FinderCutTracker()
    #expect(tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4) == .copyInsteadOfCut)
    tracker.copyFinished(pasteboardChangeCount: 5)
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 5) == .moveInsteadOfPaste)
    // The move consumes the cut, like Windows.
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 5) == .passThrough)
}

@Test func pasteBeforeCopyConfirmationStillMoves() {
    var tracker = FinderCutTracker()
    _ = tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4)
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 5) == .moveInsteadOfPaste)
}

@Test func cutWithNothingSelectedIsForgotten() {
    var tracker = FinderCutTracker()
    _ = tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4)
    tracker.copyFinished(pasteboardChangeCount: 4)
    #expect(tracker.pending == .none)
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4) == .passThrough)
}

@Test func copyingSomethingElseCancelsTheCut() {
    var tracker = FinderCutTracker()
    _ = tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4)
    tracker.copyFinished(pasteboardChangeCount: 5)
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 6) == .passThrough)
}

@Test func textFieldsAndOtherAppsAreLeftAlone() {
    var tracker = FinderCutTracker()
    #expect(tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: true, pasteboardChangeCount: 4) == .passThrough)
    #expect(tracker.handle(.cut, finderIsFrontmost: false, textInputFocused: false, pasteboardChangeCount: 4) == .passThrough)
    #expect(tracker.pending == .none)
}

@Test func pastingIntoAnotherAppKeepsTheCut() {
    var tracker = FinderCutTracker()
    _ = tracker.handle(.cut, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 4)
    tracker.copyFinished(pasteboardChangeCount: 5)
    #expect(tracker.handle(.paste, finderIsFrontmost: false, textInputFocused: false, pasteboardChangeCount: 5) == .passThrough)
    #expect(tracker.handle(.paste, finderIsFrontmost: true, textInputFocused: false, pasteboardChangeCount: 5) == .moveInsteadOfPaste)
}
