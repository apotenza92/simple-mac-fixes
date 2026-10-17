import AppKit

/// Option-clicking a folder in the Dock opens it in Finder instead of showing
/// the stack.
///
/// Ported from Dockmint's folder click action with only the Finder route kept.
/// Clicks without Option are never hit-tested, so ordinary Dock clicks pay
/// nothing; an Option-click on a folder is consumed so the stack stays closed.
@MainActor
public final class DockFolderFinderFeature {
    private static let dragThreshold: CGFloat = 6

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: (url: URL, location: CGPoint)?
    private var dragged = false

    public init() {}

    public var isRunning: Bool { port != nil }

    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let feature = Unmanaged<DockFolderFinderFeature>.fromOpaque(userInfo).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { feature.handle(type, event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    public func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        pending = nil
    }

    nonisolated static func isOptionClick(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]) == .maskAlternate
    }

    /// Returns false to drop the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            pending = nil
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        case .leftMouseDown:
            pending = nil
            guard Self.isOptionClick(event.flags),
                  let url = DockHitTest.folderURLAtPoint(event.location) else { return true }
            pending = (url, event.location)
            dragged = false
            return false
        case .leftMouseDragged:
            guard let pending else { return true }
            if hypot(event.location.x - pending.location.x, event.location.y - pending.location.y) >= Self.dragThreshold {
                dragged = true
            }
            // The Dock never saw the mouse-down, so it must not see the drag either.
            return false
        case .leftMouseUp:
            guard let click = pending else { return true }
            pending = nil
            if !dragged { open(click.url) }
            return false
        default:
            return true
        }
    }

    private func open(_ folderURL: URL) {
        guard folderURL.isFileURL,
              let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folderURL], withApplicationAt: finder, configuration: configuration)
    }
}
