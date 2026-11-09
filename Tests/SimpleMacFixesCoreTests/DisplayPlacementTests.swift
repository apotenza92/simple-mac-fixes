import CoreGraphics
import Testing
@testable import SimpleMacFixesCore

private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let leftAbove = CGRect(x: -1124, y: -1080, width: 1920, height: 1080)
private let rightAbove = CGRect(x: 796, y: -1080, width: 1920, height: 1080)
private let screens = [builtIn, leftAbove, rightAbove]

@Test func menuBarItemOnADisplayAboveAnotherIsNotMeasuredAgainstTheOneBelow() {
    let onLeftAbove = CGRect(x: 500, y: -1076, width: 22, height: 22)
    #expect(DisplayPlacement.screen(forMenuBarItem: onLeftAbove, among: screens) == leftAbove)
}

@Test func menuBarItemOnTheLowerDisplayStaysOnIt() {
    let onBuiltIn = CGRect(x: 1300, y: 5, width: 22, height: 22)
    #expect(DisplayPlacement.screen(forMenuBarItem: onBuiltIn, among: screens) == builtIn)
}

@Test func hiddenMenuBarItemAboveTheScreenStillBelongsToIt() {
    let tuckedAway = CGRect(x: 2400, y: -1110, width: 22, height: 22)
    #expect(DisplayPlacement.screen(forMenuBarItem: tuckedAway, among: screens) == rightAbove)
}

@Test func menuBarItemBeyondEveryDisplayHasNoScreen() {
    let nowhere = CGRect(x: 5000, y: 0, width: 22, height: 22)
    #expect(DisplayPlacement.screen(forMenuBarItem: nowhere, among: screens) == nil)
}

@Test func fullScreenIsReadPerDisplay() {
    let entries: [[String: Any]] = [
        ["Display Identifier": "AAAA", "Current Space": ["type": 0]],
        ["Display Identifier": "BBBB", "Current Space": ["type": 4]],
    ]
    #expect(!DisplayPlacement.isFullScreenShowing(onDisplayIdentifier: "AAAA", in: entries))
    #expect(DisplayPlacement.isFullScreenShowing(onDisplayIdentifier: "bbbb", in: entries))
    #expect(!DisplayPlacement.isFullScreenShowing(onDisplayIdentifier: "CCCC", in: entries))
}

@Test func sharedSpacesUseTheSingleMainEntry() {
    let entries: [[String: Any]] = [["Display Identifier": "Main", "Current Space": ["type": 4]]]
    #expect(DisplayPlacement.isFullScreenShowing(onDisplayIdentifier: "AAAA", in: entries))
}
