import AppKit
import ApplicationServices
import Carbon.HIToolbox

public final class FinderCutFeature {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    private var tracker = FinderCutTracker()
    private lazy var tap = EventTap(types: [.keyDown]) { [weak self] _, event in
        self?.process(event)
        return true
    }

    public init() {}

    public var isRunning: Bool { tap.isRunning }
    @discardableResult public func start() -> Bool { tap.start() }
    public func stop() {
        tap.stop()
        tracker = FinderCutTracker()
    }

    private func process(_ event: CGEvent) {
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        let shortcut = FinderCutTracker.shortcut(
            characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
            commandOnly: modifiers == .maskCommand
        )
        guard shortcut != .other,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleIdentifier
        else { return }
        let decision = tracker.handle(
            shortcut,
            finderIsFrontmost: true,
            textInputFocused: Self.textInputFocused(),
            pasteboardChangeCount: NSPasteboard.general.changeCount
        )
        switch decision {
        case .passThrough:
            break
        case .copyInsteadOfCut:
            guard let copyKey = Self.keyCode(for: "c") else { return }
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(copyKey))
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array("c".utf16))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tracker.copyFinished(pasteboardChangeCount: NSPasteboard.general.changeCount)
            }
        case .moveInsteadOfPaste:
            event.flags.insert(.maskAlternate)
        }
    }

    /// Unknown focus counts as text so file shortcuts never break text editing.
    private static func textInputFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return true }
        let element = focused as! AXUIElement
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let name = value as? String, textRoles.contains(name) {
                return true
            }
        }
        return false
    }

    /// Finds the key that types `character` on the current layout, so Dvorak,
    /// AZERTY and other layouts copy correctly.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return CGKeyCode(kVK_ANSI_C) }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character)
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                )
                if status == noErr, length == 1, String(utf16CodeUnits: characters, count: 1) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
