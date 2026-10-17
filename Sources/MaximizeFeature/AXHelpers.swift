import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum AXHelpers {
    static func value(of attribute: String, on element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value
    }

    static func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        value(of: attribute, on: element) as? String
    }

    static func boolAttribute(_ attribute: String, on element: AXUIElement) -> Bool? {
        value(of: attribute, on: element) as? Bool
    }

    static func intAttribute(_ attribute: String, on element: AXUIElement) -> Int? {
        if let number = value(of: attribute, on: element) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    static func pointAttribute(_ attribute: String, on element: AXUIElement) -> CGPoint? {
        guard let rawValue = value(of: attribute, on: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    static func sizeAttribute(_ attribute: String, on element: AXUIElement) -> CGSize? {
        guard let rawValue = value(of: attribute, on: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    static func elementAttribute(_ attribute: String, on element: AXUIElement) -> AXUIElement? {
        guard let rawValue = value(of: attribute, on: element),
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(rawValue, to: AXUIElement.self)
    }

    static func children(of element: AXUIElement, attribute: String = kAXChildrenAttribute as String) -> [AXUIElement] {
        guard let rawValue = value(of: attribute, on: element) else {
            return []
        }

        let values: [AnyObject]
        if let array = rawValue as? [AnyObject] {
            values = array
        } else if CFGetTypeID(rawValue) == CFArrayGetTypeID(), let array = rawValue as? [AnyObject] {
            values = array
        } else {
            return []
        }

        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    static func menuTraversalChildren(of element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var seen = Set<Int>()

        for attribute in [
            kAXChildrenAttribute as String,
            kAXVisibleChildrenAttribute as String,
            "AXMenu"
        ] {
            for child in children(of: element, attribute: attribute) + [elementAttribute(attribute, on: element)].compactMap({ $0 }) {
                let key = identifier(for: child)
                if seen.insert(key).inserted {
                    results.append(child)
                }
            }
        }

        return results
    }

    static func cgRect(of window: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute as String, on: window),
              let size = sizeAttribute(kAXSizeAttribute as String, on: window) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    static func actions(for element: AXUIElement) -> [String] {
        var actions: CFArray?
        let error = AXUIElementCopyActionNames(element, &actions)
        guard error == .success, let actionNames = actions as? [String] else {
            return []
        }
        return actionNames
    }

    static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard error == .success else {
            return false
        }
        return settable.boolValue
    }

    @discardableResult
    static func set(position: CGPoint, on element: AXUIElement) -> AXError {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func set(size: CGSize, on element: AXUIElement) -> AXError {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    static func set(boolAttribute attribute: String, value: Bool, on element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    @discardableResult
    static func perform(action: String, on element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    static func raise(window: AXUIElement) -> AXError {
        perform(action: kAXRaiseAction as String, on: window)
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXParentAttribute as String, on: element)
    }

    static func window(of element: AXUIElement) -> AXUIElement? {
        if let window = elementAttribute(kAXWindowAttribute as String, on: element) {
            return window
        }

        var current: AXUIElement? = element
        while let element = current {
            let role = stringAttribute(kAXRoleAttribute as String, on: element)
            if role == (kAXWindowRole as String) {
                return element
            }
            current = parent(of: element)
        }
        return nil
    }

    static func windowNumber(of window: AXUIElement) -> Int? {
        intAttribute("AXWindowNumber", on: window)
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    static func elementsEqual(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return CFEqual(lhs, rhs)
    }

    static func pollWindowFrame(
        of window: AXUIElement,
        timeout: TimeInterval = 0.9,
        interval: TimeInterval = 0.1,
        until predicate: (CGRect) -> Bool = { _ in true }
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrame = cgRect(of: window)
        if let lastFrame, predicate(lastFrame) {
            return lastFrame
        }

        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            if let frame = cgRect(of: window) {
                lastFrame = frame
                if predicate(frame) {
                    return frame
                }
            }
        }

        return lastFrame
    }

    static func poll(
        timeout: TimeInterval = 0.9,
        interval: TimeInterval = 0.05,
        until predicate: () -> Bool
    ) -> Bool {
        if predicate() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            if predicate() {
                return true
            }
        }

        return false
    }

    static func waitForWindowFocus(
        _ window: AXUIElement,
        in pid: pid_t,
        timeout: TimeInterval = 0.6,
        interval: TimeInterval = 0.05
    ) -> Bool {
        poll(timeout: timeout, interval: interval) {
            let appElement = AXUIElementCreateApplication(pid)
            let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as String, on: appElement)
            let mainWindow = elementAttribute(kAXMainWindowAttribute as String, on: appElement)
            let isFocused = boolAttribute(kAXFocusedAttribute as String, on: window)
                ?? elementsEqual(window, focusedWindow)
            let isMain = boolAttribute(kAXMainAttribute as String, on: window)
                ?? elementsEqual(window, mainWindow)
            return isFocused && isMain
        }
    }


    private static func identifier(for element: AXUIElement) -> Int {
        Int(CFHash(element))
    }
}
