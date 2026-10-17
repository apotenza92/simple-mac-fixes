import CoreAudio
import Foundation

@MainActor
public final class AudioController: ObservableObject {
    public enum State: Equatable {
        case stopped
        case native(device: String)
        case active(device: String)
        case failed(device: String?, reason: String)
    }

    @Published public private(set) var canAdjustVolume = false
    @Published public private(set) var level: Level
    @Published public private(set) var state: State = .stopped {
        didSet { publishRuntimeState() }
    }
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            refresh()
        }
    }

    private enum Keys {
        static let enabled = "audioEnabled"
        static let percent = "volumePercent"
        static let muted = "volumeMuted"
        static let runtimeState = "runtimeAudioState"
        static let runtimeDevice = "runtimeAudioDevice"
        static let runtimeReason = "runtimeAudioReason"
    }

    private let defaults: UserDefaults
    private var pipeline: AudioPipeline?
    private var refreshTimer: Timer?
    private var activeDeviceUID: String?
    private var isRunning = false
    private var outputObservation: AudioPropertyObservation?
    private var volumeObservation: AudioPropertyObservation?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.enabled: true, Keys.percent: 50, Keys.muted: false])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        level = Level(percent: defaults.integer(forKey: Keys.percent), isMuted: defaults.bool(forKey: Keys.muted))
    }

    public var isApplyingSoftwareGain: Bool {
        if case .active = state { return true }
        return false
    }

    public var deviceName: String? {
        switch state {
        case .native(let device), .active(let device): return device
        case .failed(let device, _): return device
        case .stopped: return nil
        }
    }

    public func start() {
        isRunning = true
        outputObservation?.cancel()
        outputObservation = AudioPropertyObservation(
            object: AudioObjectID(kAudioObjectSystemObject),
            addresses: [AudioHardware.address(kAudioHardwarePropertyDefaultOutputDevice)]
        ) { [weak self] in self?.refreshIfDeviceChanged() }
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDeviceChanged() }
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
    }

    public func stop() {
        isRunning = false
        outputObservation?.cancel()
        outputObservation = nil
        volumeObservation?.cancel()
        volumeObservation = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        pipeline?.destroy()
        pipeline = nil
        activeDeviceUID = nil
        canAdjustVolume = false
        state = .stopped
    }

    public func setVolume(_ percent: Int) {
        refreshIfDeviceChanged()
        if case .native = state {
            guard let output = AudioHardware.defaultOutput(), output.uid == activeDeviceUID else { return }
            AudioHardware.setNativeVolume(output, percent: percent)
            updateNativeLevel(output)
            return
        }
        guard isApplyingSoftwareGain else { return }
        level.set(percent)
        applyLevel()
    }

    public func nudgeVolume(_ delta: Int) {
        guard isApplyingSoftwareGain else { return }
        level.nudge(delta)
        applyLevel()
    }

    public func toggleMute() {
        guard isApplyingSoftwareGain else { return }
        level.toggleMute()
        applyLevel()
    }

    public func refresh() {
        volumeObservation?.cancel()
        volumeObservation = nil
        pipeline?.destroy()
        pipeline = nil
        activeDeviceUID = nil

        canAdjustVolume = false
        guard let output = AudioHardware.defaultOutput() else {
            state = .failed(device: nil, reason: "No output device is available.")
            return
        }
        activeDeviceUID = output.uid

        // Let macOS own devices that already implement volume. The event tap
        // passes their keys through unchanged.
        guard !AudioHardware.hasNativeVolume(output) else {
            state = .native(device: output.name)
            let addresses = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].flatMap { selector in
                [UInt32(0), 1, 2].map {
                    AudioHardware.address(selector, scope: kAudioDevicePropertyScopeOutput, element: $0)
                }
            }
            volumeObservation = AudioPropertyObservation(object: output.id, addresses: addresses) { [weak self] in
                guard let self, self.activeDeviceUID == output.uid, case .native = self.state else { return }
                self.updateNativeLevel(output)
            }
            updateNativeLevel(output)
            return
        }
        // Native changes never overwrite the saved software gain for fixed-volume outputs.
        level = Level(percent: defaults.integer(forKey: Keys.percent), isMuted: defaults.bool(forKey: Keys.muted))
        guard isEnabled else {
            state = .stopped
            return
        }
        guard let process = AudioHardware.processObject() else {
            state = .failed(device: output.name, reason: "Core Audio could not identify Simple Mac Fixes.")
            return
        }

        do {
            let pipeline = try AudioPipeline(output: output, excluding: process, gain: level.gain)
            try pipeline.start()
            self.pipeline = pipeline
            state = .active(device: output.name)
            canAdjustVolume = true
        } catch {
            pipeline?.destroy()
            pipeline = nil
            state = .failed(device: output.name, reason: error.localizedDescription)
        }
    }

    private func applyLevel() {
        defaults.set(level.percent, forKey: Keys.percent)
        defaults.set(level.isMuted, forKey: Keys.muted)
        pipeline?.gain = level.gain
    }

    private func publishRuntimeState() {
        switch state {
        case .stopped:
            defaults.set("stopped", forKey: Keys.runtimeState)
            defaults.removeObject(forKey: Keys.runtimeDevice)
            defaults.removeObject(forKey: Keys.runtimeReason)
        case .native(let device):
            defaults.set("native", forKey: Keys.runtimeState)
            defaults.set(device, forKey: Keys.runtimeDevice)
            defaults.removeObject(forKey: Keys.runtimeReason)
        case .active(let device):
            defaults.set("active", forKey: Keys.runtimeState)
            defaults.set(device, forKey: Keys.runtimeDevice)
            defaults.removeObject(forKey: Keys.runtimeReason)
        case .failed(let device, let reason):
            defaults.set("failed", forKey: Keys.runtimeState)
            defaults.set(device, forKey: Keys.runtimeDevice)
            defaults.set(reason, forKey: Keys.runtimeReason)
        }
    }

    private func updateNativeLevel(_ output: AudioDevice) {
        guard let current = AudioHardware.nativeLevel(output) else {
            canAdjustVolume = false
            return
        }
        if !canAdjustVolume { canAdjustVolume = true }
        guard level != current || defaults.object(forKey: "runtimeNativeVolumePercent") == nil else { return }
        level = current
        defaults.set(current.percent, forKey: "runtimeNativeVolumePercent")
        defaults.set(current.isMuted, forKey: "runtimeNativeVolumeMuted")
    }

    private func refreshIfDeviceChanged() {
        guard isRunning else { return }
        let output = AudioHardware.defaultOutput()
        if output?.uid != activeDeviceUID {
            refresh()
        } else if case .native = state, let output {
            updateNativeLevel(output)
        }
    }
}
