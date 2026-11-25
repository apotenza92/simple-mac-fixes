import AppKit
import ApplicationServices

/// Turns on the page accessibility of each Electron app that comes to the front.
///
/// An Electron app shows its page to accessibility only when an app asks for it, as
/// screen readers and window tools do. Without the page, a double-click on its title bar
/// cannot be told from one on a button, so it went to the system's own fill (seen in
/// GitHub Desktop and T3 Code after a fresh login, with no other tool asking). The cost
/// is some more memory and work in those apps while they run, accepted by the user.
final class ElectronAccessibility: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Macsimize.ElectronAccessibility", qos: .utility)
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    /// Processes already asked, so each is asked once.
    private var asked: Set<pid_t> = []

    func start() {
        lock.lock()
        let running = observer != nil
        lock.unlock()
        guard !running else { return }
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.turnOn(for: app)
        }
        lock.lock()
        observer = token
        lock.unlock()
        if let front = NSWorkspace.shared.frontmostApplication {
            turnOn(for: front)
        }
    }

    func stop() {
        lock.lock()
        let token = observer
        observer = nil
        lock.unlock()
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func turnOn(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard let bundleURL = app.bundleURL, Self.isElectron(bundleURL) else { return }
        lock.lock()
        let new = asked.insert(pid).inserted
        lock.unlock()
        guard new else { return }
        queue.async {
            _ = AXHelpers.set(boolAttribute: "AXManualAccessibility", value: true,
                              on: AXUIElementCreateApplication(pid))
        }
    }

    static func isElectron(_ bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        )
    }
}
