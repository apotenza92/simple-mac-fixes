import AppKit
import CoreGraphics
import Foundation

struct ScreenDescriptor: Equatable {
    let identifier: String
    let frame: CGRect
    let visibleFrame: CGRect
}

enum ScreenHelpers {
    static func currentScreens() -> [ScreenDescriptor] {
        NSScreen.screens.enumerated().map { index, screen in
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ScreenDescriptor(
                identifier: screenNumber?.stringValue ?? "screen-\(index)",
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    static func bestScreen(for windowFrame: CGRect, screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        guard !screens.isEmpty else {
            return nil
        }

        let bestByIntersection = screens.max { lhs, rhs in
            intersectionArea(windowFrame, accessibilityRect(forScreen: lhs, in: screens))
                < intersectionArea(windowFrame, accessibilityRect(forScreen: rhs, in: screens))
        }

        if let bestByIntersection,
           intersectionArea(windowFrame, accessibilityRect(forScreen: bestByIntersection, in: screens)) > 0 {
            return bestByIntersection
        }

        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return screens.min { lhs, rhs in
            distanceSquared(windowCenter, center(of: accessibilityRect(forScreen: lhs, in: screens)))
                < distanceSquared(windowCenter, center(of: accessibilityRect(forScreen: rhs, in: screens)))
        }
    }

    static func maximizeRect(for windowFrame: CGRect, screens: [ScreenDescriptor]) -> CGRect? {
        guard let screen = bestScreen(for: windowFrame, screens: screens) else {
            return nil
        }
        return accessibilityRect(forVisibleFrame: screen.visibleFrame, in: screens)
    }

    static func accessibilityRect(forVisibleFrame visibleFrame: CGRect, in screens: [ScreenDescriptor]) -> CGRect {
        let desktopTopEdge = screens.map(\.frame.maxY).max() ?? visibleFrame.maxY
        return normalized(
            rect: CGRect(
                x: visibleFrame.minX,
                y: desktopTopEdge - visibleFrame.maxY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        )
    }

    static func accessibilityRect(forScreen screen: ScreenDescriptor, in screens: [ScreenDescriptor]) -> CGRect {
        let desktopTopEdge = screens.map(\.frame.maxY).max() ?? screen.frame.maxY
        return normalized(
            rect: CGRect(
                x: screen.frame.minX,
                y: desktopTopEdge - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        )
    }

    static func normalized(rect: CGRect) -> CGRect {
        CGRect(
            x: round(rect.origin.x),
            y: round(rect.origin.y),
            width: round(rect.size.width),
            height: round(rect.size.height)
        )
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.intersection(rhs).isNull ? 0 : lhs.intersection(rhs).width * lhs.intersection(rhs).height
    }
}
