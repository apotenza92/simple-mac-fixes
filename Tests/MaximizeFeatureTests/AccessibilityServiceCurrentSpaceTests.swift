import ApplicationServices
import XCTest
@testable import MaximizeFeature

final class AccessibilityServiceCurrentSpaceTests: XCTestCase {
    func testCurrentActiveSpaceIDsCollectsLayerZeroOnscreenEntries() {
        let entries: [[String: AnyObject]] = [
            [
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowNumber as String: NSNumber(value: 11)
            ],
            [
                kCGWindowLayer as String: NSNumber(value: 3),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowNumber as String: NSNumber(value: 99)
            ]
        ]

        let spaceIDs = AccessibilityService.currentActiveSpaceIDs(entries: entries) { windowID in
            windowID == 11 ? [4, 5] : [8]
        }

        XCTAssertEqual(spaceIDs, [4, 5])
    }

    func testCurrentSpaceCandidateIncludedWhenSpacesIntersect() {
        let candidate = Self.makeCandidate(spaceIDs: [2], isOnScreen: false)

        XCTAssertTrue(
            AccessibilityService.shouldIncludeCurrentSpaceStandardCandidate(
                candidate,
                activeSpaceIDs: [2, 3]
            )
        )
    }

    func testCurrentSpaceCandidateExcludedWhenSpacesDoNotIntersect() {
        let candidate = Self.makeCandidate(spaceIDs: [9], isOnScreen: true)

        XCTAssertFalse(
            AccessibilityService.shouldIncludeCurrentSpaceStandardCandidate(
                candidate,
                activeSpaceIDs: [2, 3]
            )
        )
    }

    func testCurrentSpaceCandidateFallsBackToOnScreenWhenNoSpacesResolved() {
        let candidate = Self.makeCandidate(spaceIDs: [], isOnScreen: true)

        XCTAssertTrue(
            AccessibilityService.shouldIncludeCurrentSpaceStandardCandidate(
                candidate,
                activeSpaceIDs: []
            )
        )
    }

    func testCurrentSpaceCandidateExcludesMinimizedWindows() {
        let candidate = Self.makeCandidate(spaceIDs: [2], isOnScreen: true, isMinimized: true)

        XCTAssertFalse(
            AccessibilityService.shouldIncludeCurrentSpaceStandardCandidate(
                candidate,
                activeSpaceIDs: [2]
            )
        )
    }

    func testCurrentSpaceCGEntriesFiltersToLayerZeroEntriesInActiveSpace() {
        let entries: [[String: AnyObject]] = [
            [
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowNumber as String: NSNumber(value: 11),
                kCGWindowOwnerPID as String: NSNumber(value: 100),
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowBounds as String: [
                    "X": NSNumber(value: 10),
                    "Y": NSNumber(value: 10),
                    "Width": NSNumber(value: 500),
                    "Height": NSNumber(value: 400)
                ] as NSDictionary
            ],
            [
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowNumber as String: NSNumber(value: 12),
                kCGWindowOwnerPID as String: NSNumber(value: 101),
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowBounds as String: [
                    "X": NSNumber(value: 20),
                    "Y": NSNumber(value: 20),
                    "Width": NSNumber(value: 500),
                    "Height": NSNumber(value: 400)
                ] as NSDictionary
            ],
            [
                kCGWindowLayer as String: NSNumber(value: 2),
                kCGWindowIsOnscreen as String: NSNumber(value: true),
                kCGWindowNumber as String: NSNumber(value: 13),
                kCGWindowOwnerPID as String: NSNumber(value: 102)
            ]
        ]

        let filtered = AccessibilityService.currentSpaceCGEntries(
            entries: entries,
            activeSpaceIDs: [2]
        ) { windowID in
            switch windowID {
            case 11:
                return [2]
            case 12:
                return [9]
            default:
                return []
            }
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual((filtered.first?[kCGWindowNumber as String] as? NSNumber)?.intValue, 11)
    }

    func testMatchesRequestedIdentifierPassesWhenNoFilterSupplied() {
        XCTAssertTrue(AccessibilityService.matchesRequestedIdentifier("window-1", matchingIdentifiers: nil))
    }

    func testMatchesRequestedIdentifierFiltersToRequestedSet() {
        XCTAssertTrue(
            AccessibilityService.matchesRequestedIdentifier(
                "window-1",
                matchingIdentifiers: ["window-1", "window-2"]
            )
        )
        XCTAssertFalse(
            AccessibilityService.matchesRequestedIdentifier(
                "window-3",
                matchingIdentifiers: ["window-1", "window-2"]
            )
        )
    }

    func testMakeWindowIdentifierPrefersCGWindowIDOverWindowNumberAndTitle() {
        XCTAssertEqual(
            AccessibilityService.makeWindowIdentifier(
                pid: 42,
                cgWindowID: 321,
                windowNumber: 123,
                title: "New Tab"
            ),
            "pid:42-cgwindow:321"
        )
    }

    func testMakeWindowIdentifierFallsBackToWindowNumberWhenCGWindowIDUnavailable() {
        XCTAssertEqual(
            AccessibilityService.makeWindowIdentifier(
                pid: 42,
                cgWindowID: nil,
                windowNumber: 123,
                title: "New Tab"
            ),
            "pid:42-window:123"
        )
    }

    func testMakeWindowIdentifierFallsBackToTitleWhenNoWindowIDIsAvailable() {
        XCTAssertEqual(
            AccessibilityService.makeWindowIdentifier(
                pid: 42,
                cgWindowID: nil,
                windowNumber: nil,
                title: "New Tab"
            ),
            "pid:42-title:New Tab"
        )
    }

    func testTitleBarRectAnchorsToTopOfWindow() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 700)
        let controlFrame = CGRect(x: 112, y: 215, width: 14, height: 14)

        let rect = AccessibilityService.titleBarRect(
            forWindowFrame: windowFrame,
            controlFrame: controlFrame
        )

        XCTAssertEqual(rect.minX, windowFrame.minX)
        XCTAssertEqual(rect.width, windowFrame.width)
        XCTAssertEqual(rect.minY, windowFrame.minY, accuracy: 0.001)
        XCTAssertEqual(rect.height, 44, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 244, accuracy: 0.001)
    }

    func testFallbackTitleBarRectAnchorsToTopOfWindow() {
        let windowFrame = CGRect(x: 50, y: 75, width: 600, height: 400)

        let rect = AccessibilityService.fallbackTitleBarRect(
            forWindowFrame: windowFrame,
            fallbackTitleBarHeight: 56
        )

        XCTAssertEqual(rect.minX, windowFrame.minX)
        XCTAssertEqual(rect.width, windowFrame.width)
        XCTAssertEqual(rect.minY, windowFrame.minY)
        XCTAssertEqual(rect.height, 56, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 131, accuracy: 0.001)
    }

    func testTitleBarSupplementaryFrameRejectsFullWindowSizedGroup() {
        let windowFrame = CGRect(x: 50, y: 75, width: 600, height: 400)
        let frame = windowFrame

        XCTAssertFalse(
            AccessibilityService.isLikelyTitleBarSupplementaryFrame(
                frame,
                in: windowFrame
            )
        )
    }

    func testTitleBarSupplementaryFrameAcceptsTopAttachedToolbar() {
        let windowFrame = CGRect(x: 50, y: 75, width: 600, height: 400)
        let frame = CGRect(x: 50, y: 75, width: 600, height: 44)

        XCTAssertTrue(
            AccessibilityService.isLikelyTitleBarSupplementaryFrame(
                frame,
                in: windowFrame
            )
        )
    }

    func testTitleBarControlFrameAcceptsTopAttachedTrafficLight() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 700)
        let frame = CGRect(x: 112, y: 215, width: 14, height: 14)

        XCTAssertTrue(
            AccessibilityService.isLikelyTitleBarControlFrame(
                frame,
                in: windowFrame
            )
        )
    }

    func testTitleBarControlFrameRejectsBottomAttachedGhostButton() {
        let windowFrame = CGRect(x: 131, y: 538, width: 1252, height: 902)
        let frame = CGRect(x: 1, y: 1425, width: 12, height: 14)

        XCTAssertFalse(
            AccessibilityService.isLikelyTitleBarControlFrame(
                frame,
                in: windowFrame
            )
        )
    }

    func testHitTestResolvedTitleBarInteractionAcceptsOriginalLocationInsideTitleBar() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let activationRect = CGRect(x: 100, y: 100, width: 800, height: 48)

        XCTAssertTrue(
            AccessibilityService.shouldAcceptHitTestResolvedTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 120),
                windowFrame: windowFrame,
                activationRect: activationRect
            )
        )
    }

    func testHitTestResolvedTitleBarInteractionRejectsOriginalLocationOutsideWindow() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let activationRect = CGRect(x: 100, y: 100, width: 800, height: 48)

        XCTAssertFalse(
            AccessibilityService.shouldAcceptHitTestResolvedTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 760),
                windowFrame: windowFrame,
                activationRect: activationRect
            )
        )
    }

    func testHitTestResolvedTitleBarInteractionAcceptsOriginalLocationInsideSupplementaryChrome() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let activationRect = CGRect(x: 100, y: 100, width: 800, height: 84)

        XCTAssertTrue(
            AccessibilityService.shouldAcceptHitTestResolvedTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 170),
                windowFrame: windowFrame,
                activationRect: activationRect
            )
        )
    }

    func testFallbackTitleBarInteractionAcceptsOriginalLocationInsideDraggableRect() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let draggableRect = CGRect(x: 100, y: 100, width: 800, height: 48)

        XCTAssertTrue(
            AccessibilityService.shouldAcceptFallbackTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 120),
                windowFrame: windowFrame,
                draggableRect: draggableRect,
                hasReliableFallbackEvidence: true
            )
        )
    }

    func testFallbackTitleBarInteractionRejectsSupplementaryChromeOutsideDraggableRect() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let draggableRect = CGRect(x: 100, y: 100, width: 800, height: 48)

        XCTAssertFalse(
            AccessibilityService.shouldAcceptFallbackTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 170),
                windowFrame: windowFrame,
                draggableRect: draggableRect,
                hasReliableFallbackEvidence: true
            )
        )
    }

    func testFallbackTitleBarInteractionRejectsMissingWindowFrame() {
        XCTAssertFalse(
            AccessibilityService.shouldAcceptFallbackTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 120),
                windowFrame: nil,
                draggableRect: CGRect(x: 100, y: 100, width: 800, height: 48),
                hasReliableFallbackEvidence: true
            )
        )
    }

    func testFallbackTitleBarInteractionRejectsWhenReliableFallbackEvidenceIsMissing() {
        XCTAssertFalse(
            AccessibilityService.shouldAcceptFallbackTitleBarInteraction(
                originalLocation: CGPoint(x: 220, y: 120),
                windowFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
                draggableRect: CGRect(x: 100, y: 100, width: 800, height: 48),
                hasReliableFallbackEvidence: false
            )
        )
    }

    func testFallbackTitleBarProbePointsStayInTopBand() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 700)

        let points = AccessibilityService.fallbackTitleBarProbePoints(for: windowFrame)

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].x, 298, accuracy: 0.001)
        XCTAssertEqual(points[1].x, 550, accuracy: 0.001)
        XCTAssertEqual(points[2].x, 802, accuracy: 0.001)
        XCTAssertEqual(points[0].y, 226, accuracy: 0.001)
    }

    func testTrustedFallbackTitleBarHitPathAcceptsWindowHit() {
        let ancestors = [
            Self.makeTitleBarHitAncestor(role: kAXWindowRole as String, actions: [], frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        ]

        XCTAssertTrue(
            AccessibilityService.isTrustedFallbackTitleBarHitPath(
                ancestors,
                in: CGRect(x: 100, y: 100, width: 800, height: 600)
            )
        )
    }

    func testTrustedFallbackTitleBarHitPathRejectsUnknownFullWindowGroupChain() {
        let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let ancestors = [
            Self.makeTitleBarHitAncestor(role: kAXGroupRole as String, actions: [], frame: windowFrame),
            Self.makeTitleBarHitAncestor(role: kAXGroupRole as String, actions: [], frame: windowFrame),
            Self.makeTitleBarHitAncestor(role: kAXWindowRole as String, actions: [kAXRaiseAction as String], frame: windowFrame)
        ]

        XCTAssertFalse(
            AccessibilityService.isTrustedFallbackTitleBarHitPath(
                ancestors,
                in: windowFrame
            )
        )
    }

    func testInteractiveTitleBarElementRejectsButtons() {
        XCTAssertTrue(
            AccessibilityService.isInteractiveTitleBarElement(
                role: kAXButtonRole as String,
                actions: []
            )
        )
    }

    func testInteractiveTitleBarElementRejectsPressActions() {
        XCTAssertFalse(
            AccessibilityService.isInteractiveTitleBarElement(
                role: kAXStaticTextRole as String,
                actions: [kAXPressAction as String]
            )
        )
    }

    func testInteractiveTitleBarElementRejectsPressActionsForUnknownRole() {
        XCTAssertTrue(
            AccessibilityService.isInteractiveTitleBarElement(
                role: nil,
                actions: [kAXPressAction as String]
            )
        )
    }

    private struct FakeNode {
        let role: String
        let frame: CGRect?
        var children: [FakeNode] = []
    }

    private static func containsInteractiveElement(at point: CGPoint, in root: FakeNode) -> Bool {
        AccessibilityService.containsInteractiveElement(
            at: point,
            root: root,
            children: \.children,
            frame: \.frame,
            role: { $0.role },
            actions: { _ in [] }
        )
    }

    /// Chromium tab strips: the hit test returns a group layered over the tab, while
    /// the tab and its close button sit in a sibling branch.
    private static let chromiumWindow = FakeNode(role: kAXWindowRole as String, frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
        FakeNode(role: kAXGroupRole as String, frame: CGRect(x: 0, y: 0, width: 800, height: 40), children: [
            FakeNode(role: kAXGroupRole as String, frame: CGRect(x: 0, y: 0, width: 800, height: 40)),
            FakeNode(role: "AXTabGroup", frame: CGRect(x: 80, y: 0, width: 600, height: 40), children: [
                FakeNode(role: kAXRadioButtonRole as String, frame: CGRect(x: 80, y: 0, width: 240, height: 40), children: [
                    FakeNode(role: kAXButtonRole as String, frame: CGRect(x: 290, y: 6, width: 28, height: 28))
                ])
            ])
        ])
    ])

    func testInteractiveElementSearchFindsTabUnderOverlayGroup() {
        XCTAssertTrue(Self.containsInteractiveElement(at: CGPoint(x: 150, y: 20), in: Self.chromiumWindow))
    }

    func testInteractiveElementSearchAllowsEmptyTabStrip() {
        XCTAssertFalse(Self.containsInteractiveElement(at: CGPoint(x: 720, y: 20), in: Self.chromiumWindow))
        XCTAssertFalse(Self.containsInteractiveElement(at: CGPoint(x: 500, y: 20), in: Self.chromiumWindow))
    }

    /// Recorded from Teams: the search icon answers from inside the page, with no control
    /// among its first ten ancestors, while empty title-bar space answers from the
    /// window's own views.
    func testWebContentIsNotTitleBar() {
        let group = kAXGroupRole as String
        let searchIcon: [String?] = [group, group, group, group, group, group, group, "AXWebArea", kAXScrollAreaRole as String]
            + Array(repeating: group, count: 8) + [kAXUnknownRole as String]
        let emptyTitleBar: [String?] = [group, group, group, kAXUnknownRole as String]

        XCTAssertTrue(AccessibilityService.isInsideWebContent(roles: searchIcon))
        XCTAssertFalse(AccessibilityService.isInsideWebContent(roles: emptyTitleBar))
    }

    func testInteractiveTitleBarElementAllowsPassiveGroups() {
        XCTAssertFalse(
            AccessibilityService.isInteractiveTitleBarElement(
                role: kAXGroupRole as String,
                actions: []
            )
        )
    }

    func testInteractiveTitleBarElementAllowsToolbarShowMenuAction() {
        XCTAssertFalse(
            AccessibilityService.isInteractiveTitleBarElement(
                role: kAXToolbarRole as String,
                actions: [kAXShowMenuAction as String]
            )
        )
    }

    func testLikelyTabStripTabRejectsDuplicatedLeafGroupInsideTabGroup() {
        XCTAssertTrue(
            AccessibilityService.isLikelyTabStripTab(
                roles: [
                    kAXGroupRole as String,
                    kAXGroupRole as String,
                    "AXTabGroup",
                    kAXWindowRole as String
                ],
                frames: [
                    CGRect(x: 201, y: 120, width: 248, height: 41),
                    CGRect(x: 201, y: 120, width: 248, height: 41),
                    CGRect(x: 198, y: 120, width: 842, height: 41),
                    CGRect(x: 120, y: 120, width: 920, height: 640)
                ]
            )
        )
    }

    func testLikelyTabStripTabAllowsSingleSpacerGroupInsideTabGroup() {
        XCTAssertFalse(
            AccessibilityService.isLikelyTabStripTab(
                roles: [
                    kAXGroupRole as String,
                    "AXTabGroup",
                    kAXWindowRole as String
                ],
                frames: [
                    CGRect(x: 481, y: 120, width: 559, height: 41),
                    CGRect(x: 198, y: 120, width: 842, height: 41),
                    CGRect(x: 120, y: 120, width: 920, height: 640)
                ]
            )
        )
    }

    private static func makeCandidate(
        spaceIDs: Set<Int>,
        isOnScreen: Bool,
        isMinimized: Bool = false
    ) -> WindowCandidate {
        WindowCandidate(
            axWindow: AXUIElementCreateSystemWide(),
            cgWindowID: 1,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            layer: 0,
            alpha: 1,
            isOnScreen: isOnScreen,
            subrole: nil,
            spaceIDs: spaceIDs,
            isMinimized: isMinimized
        )
    }

    private static func makeTitleBarHitAncestor(role: String?, actions: [String], frame: CGRect?) -> AccessibilityService.TitleBarHitAncestor {
        AccessibilityService.TitleBarHitAncestor(role: role, actions: actions, frame: frame)
    }
}
