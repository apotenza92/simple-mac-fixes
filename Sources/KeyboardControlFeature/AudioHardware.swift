import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum AudioHardware {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var property = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.size else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }

    static func defaultOutput() -> AudioDevice? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let id = objectIDs(system, selector: kAudioHardwarePropertyDefaultOutputDevice).first,
              id != kAudioObjectUnknown,
              let uid = string(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, uid: uid, name: string(id, selector: kAudioObjectPropertyName) ?? uid)
    }

    static func processObject(pid: pid_t = getpid()) -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                system,
                &property,
                UInt32(MemoryLayout<pid_t>.size),
                $0,
                &size,
                &value
            )
        }
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    static func hasNativeVolume(_ device: AudioDevice) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var property = address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement(element)
            )
            guard AudioObjectHasProperty(device.id, &property) else { continue }
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device.id, &property, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    private static func volumeProperties(_ device: AudioDevice) -> [AudioObjectPropertyAddress] {
        let properties = [0, 1, 2].map {
            address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput,
                    element: AudioObjectPropertyElement($0))
        }.filter { candidate in
            var property = candidate
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device.id, &property)
                && AudioObjectIsPropertySettable(device.id, &property, &settable) == noErr
                && settable.boolValue
        }
        // A master control already affects every channel. Do not also write the channels.
        if let master = properties.first(where: { $0.mElement == kAudioObjectPropertyElementMain }) {
            return [master]
        }
        return properties
    }

    private static func scalar(_ device: AudioDevice, property: AudioObjectPropertyAddress) -> Float32? {
        var property = property
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device.id, &property, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    static func nativeLevel(_ device: AudioDevice) -> Level? {
        let values = volumeProperties(device).compactMap { scalar(device, property: $0) }
        guard let maximum = values.max() else { return nil }
        var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device.id, &mute) {
            _ = AudioObjectGetPropertyData(device.id, &mute, 0, nil, &size, &muted)
        }
        return Level(percent: Int((maximum * 100).rounded()), isMuted: muted != 0)
    }

    static func setNativeVolume(_ device: AudioDevice, percent: Int) {
        let properties = volumeProperties(device)
        let values = properties.compactMap { scalar(device, property: $0) }
        guard values.count == properties.count, !values.isEmpty else { return }
        let adjusted = nativeChannelVolumes(values, percent: percent)
        var succeeded = true
        for (candidate, newValue) in zip(properties, adjusted) {
            var property = candidate
            var value = newValue
            if AudioObjectSetPropertyData(device.id, &property, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) != noErr {
                succeeded = false
            }
        }
        // Match the existing slider: moving it unmutes, after setting the new level.
        if succeeded {
            var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(device.id, &mute),
               AudioObjectIsPropertySettable(device.id, &mute, &settable) == noErr, settable.boolValue {
                var value: UInt32 = 0
                _ = AudioObjectSetPropertyData(device.id, &mute, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &value)
            }
        }
    }

    static func nativeChannelVolumes(_ values: [Float32], percent: Int) -> [Float32] {
        let target = Float32(Level.clamp(percent)) / 100
        let maximum = values.max() ?? 0
        // Preserve the channel balance instead of resetting left/right on every drag.
        return values.map { maximum > 0 ? min(1, max(0, $0 / maximum * target)) : target }
    }

    static func describe(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        let bytes = [
            UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return "'\(String(bytes: bytes, encoding: .ascii)!)' (\(status))"
        }
        return String(status)
    }
}
