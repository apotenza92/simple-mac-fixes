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
        self?.process(event) ?? true
    }

    public init() {}

    public var isRunning: Bool { tap.isRunning }
    @discardableResult public func start() -> Bool { tap.start() }
    public func stop() {
        tap.stop()
        tracker = FinderCutTracker()
    }

    /// Returns false to drop the key press.
    private func process(_ event: CGEvent) -> Bool {
        // Every key press on the Mac comes through here; ordinary typing leaves at once.
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        guard modifiers == .maskCommand else { return true }
        let shortcut = FinderCutTracker.shortcut(
            characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
            commandOnly: true
        )
        guard shortcut != .other,
              let finder = Self.targetApplication(of: event),
              finder.bundleIdentifier == Self.finderBundleIdentifier
        else { return true }
        let decision = tracker.handle(
            shortcut,
            finderIsFrontmost: true,
            textInputFocused: Self.textInputFocused(in: finder.processIdentifier),
            pasteboardChangeCount: NSPasteboard.general.changeCount
        )
        // Editing the key press in place does not reach Finder's menus, so the
        // press is dropped and a fresh shortcut is typed in its place. That one
        // comes back through this tap as an ordinary shortcut and passes through.
        switch decision {
        case .passThrough:
            return true
        case .copyInsteadOfCut:
            guard Self.type("c", flags: .maskCommand) else { return true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tracker.copyFinished(pasteboardChangeCount: NSPasteboard.general.changeCount)
            }
            return false
        case .moveInsteadOfPaste:
            // Command-Option-V is Finder's Move Item Here.
            return !Self.type("v", flags: [.maskCommand, .maskAlternate])
        }
    }

    private static func type(_ character: Character, flags: CGEventFlags) -> Bool {
        guard let key = keyCode(for: character) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// The app the key is being delivered to. The workspace's frontmost app can
    /// lag behind a click into another app, so it is only the fallback.
    private static func targetApplication(of event: CGEvent) -> NSRunningApplication? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) { return app }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Unknown focus counts as text so file shortcuts never break text editing.
    /// Asks Finder itself, because the system-wide focused element fails on recent macOS.
    private static func textInputFocused(in finderPID: pid_t) -> Bool {
        let finder = AXUIElementCreateApplication(finderPID)
        AXUIElementSetMessagingTimeout(finder, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(finder, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
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
