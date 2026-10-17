import ApplicationServices
import CoreGraphics
import Foundation

struct WindowInterceptionKey: Hashable, Sendable {
    let pid: pid_t
    let windowIdentifier: String
    let windowNumber: Int?
}

struct ManagedWindowMutationExpectation: Equatable, Sendable {
    let sourceFrame: CGRect
    let destinationFrame: CGRect
    let observedFrame: CGRect?
    let restored: Bool
}

struct ClickedWindowContext: @unchecked Sendable {
    let appName: String
    let bundleIdentifier: String?
    let pid: pid_t
    let clickLocation: CGPoint
    let buttonElement: AXUIElement
    let windowElement: AXUIElement
    let windowIdentifier: String
    let windowNumber: Int?
    let windowTitle: String?
    let elementRole: String?
    let elementSubrole: String?
    let availableActions: [String]
    let windowFrame: CGRect?
    let canSetPosition: Bool
    let canSetSize: Bool
    let isResizable: Bool
    let isFullScreen: Bool
    let isMainWindow: Bool
    let isFocusedWindow: Bool

    var appDescriptor: String {
        if let bundleIdentifier {
            return "\(appName) (\(bundleIdentifier))"
        }
        return appName
    }

    var interceptionKey: WindowInterceptionKey {
        WindowInterceptionKey(
            pid: pid,
            windowIdentifier: windowIdentifier,
            windowNumber: windowNumber
        )
    }
}

struct TitleBarInteractionContext: @unchecked Sendable {
    let draggableRect: CGRect
    let activationRect: CGRect
    let allowsActivationOutsideDraggableRect: Bool
    let windowContext: ClickedWindowContext
}
