import AppKit
import Combine
import Foundation

@MainActor
public final class DisplayConnectionController: ObservableObject {
    public struct Display: Identifiable, Equatable {
        public let id: UInt32
        public let key: String
        public let name: String
        public let isEnabled: Bool
        public let canToggle: Bool
        public let physical: Bool
        public init(id: UInt32, key: String, name: String, isEnabled: Bool, canToggle: Bool, physical: Bool) {
            self.id = id; self.key = key; self.name = name
            self.isEnabled = isEnabled; self.canToggle = canToggle; self.physical = physical
        }
    }
    @Published public private(set) var displays: [Display] = []
    @Published public private(set) var isChanging = false
    @Published public private(set) var errorMessage: String?
    public var onTopologyChange: (() -> Void)?
    public var showsCheckboxes: Bool { displays.filter(\.physical).count > 1 }
    private var timer: Timer?
    private var names: [String: String] = [:]
    private var running = false
    private lazy var worker = DisplayConnectionWorker { [weak self] screens, disabled, error, completed in
        DispatchQueue.main.async { self?.receive(screens, disabled: disabled, error: error, completed: completed) }
    }

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func refresh() {
        guard running, !isChanging else { return }
        let worker = self.worker
        worker.queue.async { worker.refresh() }
    }

    public func setEnabled(_ enabled: Bool, for key: String) {
        guard running, !isChanging else { return }
        isChanging = true
        errorMessage = nil
        let worker = self.worker
        worker.queue.async { worker.setEnabled(enabled, key: key) }
    }

    public func restoreAll() {
        guard running else { return }
        isChanging = true
        let worker = self.worker
        worker.queue.async { worker.restoreAll() }
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        let worker = self.worker
        // No callbacks synchronously wait on main, so quit can wait for bounded
        // recovery. If macOS stalls, pipe EOF still lets helpers finish later.
        worker.queue.sync { worker.restoreAll() }
    }

    private func receive(_ screens: [DisplayConnection.Screen], disabled: Set<String>, error: String?, completed: Bool) {
        guard running else { return }
        guard !isChanging || completed else { return }
        var next: [Display] = []
        for screen in screens where screen.online || (disabled.contains(screen.key) && screen.physical) {
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screen.id
            }?.localizedName ?? names[screen.key] ?? (screen.builtIn ? "Built-in Display" : "External Display")
            names[screen.key] = name
            next.append(Display(id: screen.id, key: screen.key, name: name, isEnabled: screen.online,
                canToggle: DisplayConnection.isAvailable && (screen.online
                    ? DisplayConnection.disableError(target: screen.key, screens: screens) == nil
                    : disabled.contains(screen.key)), physical: screen.physical))
        }
        // Preserve row order when the online list puts the survivor first.
        let order = displays.map(\.key)
        next.sort {
            (order.firstIndex(of: $0.key) ?? Int.max, $0.id) < (order.firstIndex(of: $1.key) ?? Int.max, $1.id)
        }
        let topologyChanged = displays.map { "\($0.id):\($0.isEnabled)" } != next.map { "\($0.id):\($0.isEnabled)" }
        if displays != next { displays = next }
        isChanging = false
        if let error { errorMessage = error }
        UserDefaults.standard.set(next.map { ["id": $0.id, "key": $0.key, "name": $0.name,
            "enabled": $0.isEnabled, "canToggle": $0.canToggle] as [String: Any] }, forKey: "runtimeDisplayConnections")
        if topologyChanged { onTopologyChange?() }
    }
}

/// All mutable state and parent-side transactions belong to this serial queue.
private final class DisplayConnectionWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.display-connections", qos: .userInitiated)
    private var leases: [String: DisplayRecoveryLease] = [:]
    private var disabled = Set<String>()
    private var retryAfter: [String: TimeInterval] = [:]
    private let publish: ([DisplayConnection.Screen], Set<String>, String?, Bool) -> Void

    init(publish: @escaping ([DisplayConnection.Screen], Set<String>, String?, Bool) -> Void) { self.publish = publish }

    func refresh(error: String? = nil, completed: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        var message = error
        for (key, lease) in Array(leases) where !lease.process.isRunning {
            leases.removeValue(forKey: key)
        }
        do {
            var screens = try DisplayConnection.screens()
            // Retain only our recovery intent while hardware is absent. It is
            // not shown as attached and is never a request to disable on replug.
            // This also recovers a child crash while the main app survives.
            for key in disabled where leases[key] == nil {
                guard let screen = screens.first(where: { $0.key == key }), !screen.online && screen.physical,
                      ProcessInfo.processInfo.systemUptime >= (retryAfter[key] ?? 0) else { continue }
                retryAfter[key] = ProcessInfo.processInfo.systemUptime + 10
                do { try DisplayConnection.restore(key: key) }
                catch { message = error.localizedDescription }
                screens = try DisplayConnection.screens()
            }
            disabled = disabled.filter { key in !screens.contains { $0.key == key && $0.online } }
            retryAfter = retryAfter.filter { disabled.contains($0.key) }
            publish(screens, disabled, message, completed)
        } catch { publish([], disabled, error.localizedDescription, completed) }
    }

    func setEnabled(_ enabled: Bool, key: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            if enabled {
                if let lease = leases[key] {
                    lease.requestRestore()
                    guard lease.waitForExit() else { throw DisplayConnection.Failure(message: "Display restoration is taking longer than expected. Try enabling it again.") }
                    leases.removeValue(forKey: key)
                }
                try DisplayConnection.restore(key: key)
                disabled.remove(key)
            } else {
                guard leases[key] == nil else { refresh(completed: true); return }
                let lease = try DisplayRecoveryLease(key: key)
                leases[key] = lease
                disabled.insert(key)
            }
            refresh(completed: true)
        } catch { refresh(error: error.localizedDescription, completed: true) }
    }

    func restoreAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        for lease in leases.values { lease.requestRestore() }
        var message: String?
        for (key, lease) in Array(leases) {
            if lease.waitForExit() { leases.removeValue(forKey: key) }
            else { message = "A display is still being restored." }
        }
        for key in disabled where leases[key] == nil {
            guard let screen = try? DisplayConnection.screens().first(where: { $0.key == key }), screen.physical else { continue }
            do { try DisplayConnection.restore(key: key) }
            catch { message = error.localizedDescription }
        }
        refresh(error: message, completed: true)
    }
}
