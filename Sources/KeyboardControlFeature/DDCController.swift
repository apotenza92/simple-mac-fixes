import AppKit
import CoreGraphics
import Foundation
import IOKit
import QuartzCore

@MainActor
public final class DDCController: ObservableObject {
    public enum Method: String { case native, ddc, software, unavailable }
    public struct Display: Identifiable, Equatable {
        public let id: CGDirectDisplayID
        public let name: String
        public var percent: Double
        public var method: Method
        public let isBuiltIn: Bool
        public var canAdjust: Bool { method != .unavailable }
    }

    private typealias CreateFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferFunction = @convention(c)
        (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private struct Endpoint {
        let service: CFTypeRef
        let maximum: Int
        let current: Double
        let name: String?
        let serial: UInt32
    }

    @Published public private(set) var displays: [Display] = []
    @Published public private(set) var controlledDisplayIDs: [CGDirectDisplayID] = []
    @Published public var isLinked: Bool {
        didSet {
            stopNativeKeyBurst()
            defaults.set(isLinked, forKey: "brightnessLinked")
            needsLinkSnap = isLinked
            if isLinked && !isDiscovering {
                snapFollowersToMaster()
                needsLinkSnap = false
                publishState()
            }
        }
    }
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "brightnessEnabled")
            if isEnabled { rediscover() } else {
                isDiscovering = false
                cancelWrites()
                softwareBrightness.remove()
                for index in displays.indices where displays[index].method == .software { displays[index].percent = 100 }
                publishState()
            }
        }
    }
    public var isAvailable: Bool { isEnabled && displays.contains { $0.canAdjust } }
    public var isUsingSoftwareBrightness: Bool { displays.contains { $0.method == .software } }
    public var hasActiveBuiltInDisplay: Bool { displays.contains { $0.isBuiltIn && CGDisplayIsActive($0.id) != 0 } }
    public var targetDisplayID: CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }.flatMap(Self.screenID)
            ?? displays.first?.id
    }
    public var percent: Double { displays.first(where: { $0.id == targetDisplayID })?.percent ?? 100 }
    public var pendingPercent: Double { percent }
    public var shouldConsumeBrightnessKeys: Bool {
        guard isAvailable else { return false }
        if isLinked { return displays.first { $0.id == masterDisplayID }?.method != .native }
        return displays.first { $0.id == targetDisplayID }?.method != .native
    }

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.apotenza.SimpleMacFixes.ddc", qos: .userInitiated)
    private let create: CreateFunction?
    private let writeI2C: TransferFunction?
    private let readI2C: TransferFunction?
    private let softwareBrightness = SoftwareBrightness()
    private var brightnessIdentities: [CGDirectDisplayID: String] = [:]
    private var pendingShades: DispatchWorkItem?
    private var brightnessMemory: SoftwareBrightnessMemory { .init(defaults: defaults) }
    private var endpoints: [CGDirectDisplayID: Endpoint] = [:]
    private var pendingStatePublish: DispatchWorkItem?
    private var pendingWrites: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var revisions: [CGDirectDisplayID: Int] = [:]
    private var discoveryGeneration = 0
    private var pollTimer: Timer?
    private var nativeKeyBurstActive = false
    private var nativeKeyDisplayLink: CADisplayLink?
    private lazy var frameTarget = BrightnessFrameTarget { [weak self] in self?.sampleNativeKeyBurst() }
    private var nativeKeyMaster: CGDirectDisplayID?
    private var nativeKeyDeadline: TimeInterval = 0
    private var nativeKeyLastHUD: TimeInterval = 0
    private var nativeKeyCompletion: (@MainActor () -> Void)?
    private var hasCompletedInitialDiscovery = false
    private var isDiscovering = false
    private var needsLinkSnap = false

    public var masterDisplayID: CGDirectDisplayID? {
        Self.masterID(available: displays.filter { $0.canAdjust }.map(\.id), main: CGMainDisplayID())
    }

    nonisolated static func masterID(available: [CGDirectDisplayID], main: CGDirectDisplayID) -> CGDirectDisplayID? {
        available.contains(main) ? main : available.first
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["brightnessEnabled": true, "brightnessLinked": false])
        isEnabled = defaults.bool(forKey: "brightnessEnabled")
        isLinked = defaults.bool(forKey: "brightnessLinked")
        create = Self.symbol("IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFunction.self) }
        writeI2C = Self.symbol("IOAVServiceWriteI2C").map { unsafeBitCast($0, to: TransferFunction.self) }
        readI2C = Self.symbol("IOAVServiceReadI2C").map { unsafeBitCast($0, to: TransferFunction.self) }
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public func rediscover() {
        cancelWrites()
        let epoch = discoveryGeneration
        if pollTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshNativeLevels() }
            }
            pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        isDiscovering = true
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let identities = ids.prefix(Int(count)).compactMap { id -> (CGDirectDisplayID, String)? in
            guard CGDisplayIsBuiltin(id) == 0,
                  let key = SoftwareBrightnessMemory.key(vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id)) else { return nil }
            return (id, key)
        }
        let groups = Dictionary(grouping: identities, by: { $0.1 })
        brightnessIdentities = Dictionary(uniqueKeysWithValues: identities.filter { groups[$0.1]?.count == 1 })
        displays = ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first { Self.screenID($0) == id }
            let native = NativeBrightness.get(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let active = CGDisplayIsActive(id) != 0 && screen != nil
            let method: Method = !active ? .unavailable : native != nil ? .native : builtIn ? .unavailable : .software
            return Display(id: id, name: screen?.localizedName ?? "Display \(id)",
                           percent: native.map { Double($0) * 100 }
                            ?? (brightnessMemory.level(for: brightnessIdentities[id])
                                ?? (previous[id]?.method == .software ? previous[id]!.percent : 100)),
                           method: method, isBuiltIn: builtIn)
        }
        endpoints.removeAll()
        configureShades()
        publishState()
        guard isEnabled else { isDiscovering = false; return }
        let create = self.create, write = self.writeI2C, read = self.readI2C
        queue.async { [weak self] in
            let found = Self.discover(create: create, writeI2C: write, readI2C: read)
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.discoveryGeneration == epoch else { return }
                let candidates = self.displays.filter { !$0.isBuiltIn && $0.method == .software }
                for display in candidates {
                    let matching = found.filter { endpoint in
                        endpoint.name == display.name && (endpoint.serial == 0 || CGDisplaySerialNumber(display.id) == 0
                            || endpoint.serial == CGDisplaySerialNumber(display.id))
                    }
                    let sameName = candidates.filter { $0.name == display.name }
                    let endpoint: Endpoint?
                    if matching.count == 1 && (sameName.count == 1 || (matching[0].serial != 0 && CGDisplaySerialNumber(display.id) == matching[0].serial)) {
                        endpoint = matching[0]
                    } else if candidates.count == 1 && found.count == 1 && self.displays.filter({ !$0.isBuiltIn }).count == 1 { endpoint = found[0] }
                    else { endpoint = nil }
                    guard let endpoint, let index = self.displays.firstIndex(where: { $0.id == display.id }) else { continue }
                    self.endpoints[display.id] = endpoint
                    self.displays[index].method = .ddc
                    self.displays[index].percent = endpoint.current
                }
                self.isDiscovering = false
                self.configureShades()
                if !self.hasCompletedInitialDiscovery || self.needsLinkSnap {
                    self.hasCompletedInitialDiscovery = true
                    self.needsLinkSnap = false
                    self.snapFollowersToMaster()
                }
                self.publishState()
            }
        }
    }

    private func snapFollowersToMaster() {
        guard isLinked, isEnabled else { return }
        guard let master = displays.first(where: { $0.id == masterDisplayID }) else { return }
        let value = master.method == .native
            ? NativeBrightness.get(master.id).map { Level.clamp(Double($0) * 100) } ?? master.percent
            : master.percent
        let followers = Dictionary(uniqueKeysWithValues: displays.filter { $0.canAdjust && $0.id != master.id }.map { ($0.id, value) })
        applyLevels(followers, observed: [master.id: value])
    }

    private func configureShades() {
        pendingShades?.cancel()
        // Remove obsolete shades immediately, but wait for display discovery to
        // settle before creating windows in newly reconstructed display spaces.
        let retained = Set(displays.filter { $0.method == .software }.map(\.id))
        softwareBrightness.retainDisplays(isEnabled ? retained : [])
        guard isEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            self.softwareBrightness.configure(levels: Dictionary(uniqueKeysWithValues:
                self.displays.filter { $0.method == .software }.map { ($0.id, $0.percent) }))
        }
        pendingShades = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Read the native master's actual post-key level; macOS applies its own
    /// step size and animation. Never add another step to that display.
    public func nudge(up: Bool, fine: Bool, completion: @escaping @MainActor () -> Void = {}) {
        guard isAvailable else { controlledDisplayIDs = []; completion(); return }
        if isLinked, let master = displays.first(where: { $0.id == masterDisplayID }) {
            if master.method == .native {
                nativeKeyDeadline = ProcessInfo.processInfo.systemUptime + 0.4
                nativeKeyCompletion = completion
                nativeKeyMaster = master.id
                if nativeKeyDisplayLink == nil,
                   let screen = NSScreen.screens.first(where: { Self.screenID($0) == master.id }) {
                    nativeKeyBurstActive = true
                    nativeKeyLastHUD = 0
                    let link = screen.displayLink(target: frameTarget, selector: #selector(BrightnessFrameTarget.tick))
                    nativeKeyDisplayLink = link
                    link.add(to: .main, forMode: .common)
                }
                return
            }
            let target = Level.stepped(master.percent, up: up, fine: fine)
            let targets = displays.filter { $0.canAdjust }
            applyLevels(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, target) }))
            controlledDisplayIDs = targets.map(\.id)
        } else if let display = displays.first(where: { $0.id == targetDisplayID }),
                  display.canAdjust, display.method != .native {
            applyLevels([display.id: Level.stepped(display.percent, up: up, fine: fine)])
            controlledDisplayIDs = [display.id]
        } else {
            controlledDisplayIDs = []
        }
        publishState()
        completion()
    }

    private func sampleNativeKeyBurst() {
        guard isLinked, isEnabled, let master = nativeKeyMaster, masterDisplayID == master else {
            stopNativeKeyBurst()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let actual = NativeBrightness.get(master) {
            let target = Level.clamp(Double(actual) * 100)
            let followers = displays.filter { $0.canAdjust && $0.id != master }
            let changed = applyLevels(Dictionary(uniqueKeysWithValues: followers.map { ($0.id, target) }),
                                      observed: [master: target])
            if changed || now - nativeKeyLastHUD >= 0.5 {
                let ids = followers.map(\.id)
                if controlledDisplayIDs != ids { controlledDisplayIDs = ids }
                publishState()
                nativeKeyLastHUD = now
                nativeKeyCompletion?()
            }
        }
        if now >= nativeKeyDeadline { stopNativeKeyBurst() }
    }

    private func stopNativeKeyBurst() {
        nativeKeyDisplayLink?.invalidate()
        nativeKeyDisplayLink = nil
        nativeKeyMaster = nil
        nativeKeyCompletion = nil
        nativeKeyBurstActive = false
    }

    public func set(_ value: Double) {
        guard let id = targetDisplayID else { return }
        set(value, for: id)
    }

    public func set(_ value: Double, for id: CGDirectDisplayID) {
        guard isEnabled, let source = displays.first(where: { $0.id == id }), source.canAdjust else { return }
        stopNativeKeyBurst()
        let values = Self.linkedLevels(Dictionary(uniqueKeysWithValues: displays.filter { $0.canAdjust }.map { ($0.id, $0.percent) }),
                                       source: id, value: value, linked: isLinked)
        applyLevels(values)
        publishState()
    }

    nonisolated static func linkedLevels(_ levels: [CGDirectDisplayID: Double], source: CGDirectDisplayID,
                                         value: Double, linked: Bool) -> [CGDirectDisplayID: Double] {
        guard levels[source] != nil else { return [:] }
        let target = Level.clamp(value)
        guard linked else { return [source: target] }
        return levels.mapValues { _ in target }
    }

    /// A linked operation publishes one complete array, so subscribers never
    /// see a new master level paired with an old follower level.
    @discardableResult
    private func applyLevels(_ values: [CGDirectDisplayID: Double], observed: [CGDirectDisplayID: Double] = [:]) -> Bool {
        var next = displays
        for (id, value) in values {
            guard let index = next.firstIndex(where: { $0.id == id }), next[index].percent != value else { continue }
            apply(value, to: id, snapshot: &next)
        }
        for (id, value) in observed {
            if let index = next.firstIndex(where: { $0.id == id }) { next[index].percent = value }
        }
        guard next != displays else { return false }
        displays = next
        return true
    }

    private func apply(_ value: Double, to id: CGDirectDisplayID, snapshot: inout [Display]) {
        guard let index = snapshot.firstIndex(where: { $0.id == id }) else { return }
        switch snapshot[index].method {
        case .native:
            guard NativeBrightness.set(id, percent: value) else { return }
            snapshot[index].percent = NativeBrightness.get(id).map { Double($0) * 100 } ?? value
        case .software:
            brightnessMemory.remember(value, for: brightnessIdentities[id])
            softwareBrightness.set(value, for: id)
            snapshot[index].percent = value
        case .ddc:
            guard let endpoint = endpoints[id] else { return }
            let previous = snapshot[index].percent
            snapshot[index].percent = value
            pendingWrites[id]?.cancel()
            let epoch = discoveryGeneration
            let revision = (revisions[id] ?? 0) + 1
            revisions[id] = revision
            let write = writeI2C
            let work = DispatchWorkItem { [weak self] in
                let raw = Int((value / 100 * Double(endpoint.maximum)).rounded())
                let success = Self.writeLuminance(endpoint.service, value: raw, writeI2C: write)
                usleep(50_000)
                DispatchQueue.main.async {
                    guard let self, self.discoveryGeneration == epoch, self.revisions[id] == revision,
                          let index = self.displays.firstIndex(where: { $0.id == id }) else { return }
                    if !success {
                        self.displays[index].percent = previous
                        self.rediscover()
                    }
                }
            }
            pendingWrites[id] = work
            queue.async(execute: work)
        case .unavailable: break
        }
    }

    private func refreshNativeLevels() {
        // Also expire a burst if its screen stopped delivering frames (for example sleep).
        if nativeKeyBurstActive, ProcessInfo.processInfo.systemUptime >= nativeKeyDeadline {
            sampleNativeKeyBurst()
        }
        guard !nativeKeyBurstActive else { return }
        var next = displays
        for index in next.indices where next[index].method == .native {
            if let value = NativeBrightness.get(next[index].id) {
                next[index].percent = Level.clamp(Double(value) * 100)
            }
        }
        if next != displays { displays = next; publishState() }
    }

    private func publishState() {
        guard pendingStatePublish == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStatePublish = nil
            self.writeRuntimeState()
        }
        pendingStatePublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func writeRuntimeState() {
        defaults.set(isAvailable, forKey: "runtimeBrightnessAvailable")
        defaults.set(percent, forKey: "brightnessPercent")
        defaults.set(displays.map { ["id": $0.id, "name": $0.name, "percent": $0.percent, "method": $0.method.rawValue] as [String: Any] }, forKey: "runtimeDisplays")
        defaults.set(isUsingSoftwareBrightness ? "software" : "hardware", forKey: "runtimeBrightnessMode")
    }

    private func cancelWrites() {
        pendingShades?.cancel()
        pendingShades = nil
        stopNativeKeyBurst()
        discoveryGeneration += 1
        for work in pendingWrites.values { work.cancel() }
        pendingWrites.removeAll()
    }

    public func stop() {
        isDiscovering = false
        cancelWrites()
        pollTimer?.invalidate()
        pollTimer = nil
        softwareBrightness.remove()
        displays = []
        publishState()
    }

    private nonisolated static func discover(create: CreateFunction?, writeI2C: TransferFunction?, readI2C: TransferFunction?) -> [Endpoint] {
        guard let create, writeI2C != nil, readI2C != nil else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var name: String?
        var serial: UInt32 = 0
        var found: [Endpoint] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if IOObjectConformsTo(service, "AppleCLCD2") != 0 || IOObjectConformsTo(service, "IOMobileFramebufferShim") != 0 {
                let attributes = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                name = product?["ProductName"] as? String
                serial = (product?["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
            }
            guard IOObjectConformsTo(service, "DCPAVServiceProxy") != 0,
                  IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String == "External",
                  let av = create(kCFAllocatorDefault, service)?.takeRetainedValue(),
                  let reading = readLuminance(av, writeI2C: writeI2C, readI2C: readI2C) else { continue }
            found.append(Endpoint(service: av, maximum: reading.maximum,
                                  current: Level.clamp(Double(reading.current) / Double(reading.maximum) * 100),
                                  name: name, serial: serial))
        }
        return found
    }

    private nonisolated static func readLuminance(
        _ service: CFTypeRef,
        writeI2C: TransferFunction?,
        readI2C: TransferFunction?
    ) -> (current: Int, maximum: Int)? {
        guard let writeI2C, let readI2C else { return nil }
        var request = Self.readPacket(feature: 0x10)
        for _ in 0..<3 {
            let writeStatus = request.withUnsafeMutableBytes {
                writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
            }
            usleep(40_000)
            var response = [UInt8](repeating: 0, count: 11)
            let readStatus = response.withUnsafeMutableBytes {
                readI2C(service, 0x37, 0, $0.baseAddress!, UInt32($0.count))
            }
            if writeStatus == KERN_SUCCESS, readStatus == KERN_SUCCESS,
               let reading = parseLuminanceResponse(response) {
                return reading
            }
            usleep(50_000)
        }
        return nil
    }

    private nonisolated static func writeLuminance(
        _ service: CFTypeRef,
        value: Int,
        writeI2C: TransferFunction?
    ) -> Bool {
        guard let writeI2C else { return false }
        var packet = Self.writePacket(feature: 0x10, value: UInt16(clamping: value))
        return packet.withUnsafeMutableBytes {
            writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        } == KERN_SUCCESS
    }

    nonisolated static func parseLuminanceResponse(_ response: [UInt8]) -> (current: Int, maximum: Int)? {
        guard response.count == 11, response[0] == 0x6E, response[1] == 0x88,
              response[2] == 0x02, response[3] == 0, response[4] == 0x10,
              response.reduce(0x50, ^) == 0 else { return nil }
        let maximum = Int(response[6]) << 8 | Int(response[7])
        let current = Int(response[8]) << 8 | Int(response[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }

    nonisolated static func readPacket(feature: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, feature, 0]
        packet[3] = packet.dropLast().reduce(0x6E ^ 0x51, ^)
        return packet
    }

    nonisolated static func writePacket(feature: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, feature, UInt8(value >> 8), UInt8(value & 0xff), 0]
        packet[5] = packet.dropLast().reduce(0x6E ^ 0x51, ^)
        return packet
    }

    private nonisolated static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        for path in [
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        ] {
            guard let handle = dlopen(path, RTLD_NOW) else { continue }
            if let symbol = dlsym(handle, name) { return symbol }
        }
        return nil
    }
}

/// CADisplayLink retains its target; keep the controller weak through the callback.
@MainActor
private final class BrightnessFrameTarget: NSObject {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick() { callback() }
}
