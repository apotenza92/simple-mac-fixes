import AudioToolbox
import CoreAudio
import Foundation

/// A private, driverless Core Audio path. It captures all output except this
/// process, mutes the direct path, applies gain, and writes to the real output.
/// Destroying this object removes the tap, so failure is fail-open.
final class AudioPipeline {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let gainPointer: UnsafeMutablePointer<Float>
    private var started = false

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = newValue }
    }

    init(output: AudioDevice, excluding process: AudioObjectID, gain: Float) throws {
        gainPointer = .allocate(capacity: 1)
        gainPointer.initialize(to: gain)

        do {
            try build(output: output, excluding: process)
        } catch {
            gainPointer.deinitialize(count: 1)
            gainPointer.deallocate()
            throw error
        }
    }

    private func build(output: AudioDevice, excluding process: AudioObjectID) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        description.name = "Simple Mac Fixes system audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw error(tapStatus, "Could not create the system audio tap")
        }
        tapID = newTap
        let tapUID = AudioHardware.string(newTap, selector: kAudioTapPropertyUID) ?? description.uuid.uuidString

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Simple Mac Fixes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [["uid": output.uid, "drift": false]],
            kAudioAggregateDeviceTapListKey: [["uid": tapUID, "drift": true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTap)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw error(aggregateStatus, "Could not create the private output path")
        }
        aggregateID = newAggregate

        let gainPointer = self.gainPointer
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            guard let input = inputs.last, let sourceData = input.mData else {
                for output in outputs where output.mData != nil {
                    memset(output.mData!, 0, Int(output.mDataByteSize))
                }
                return
            }

            let source = sourceData.assumingMemoryBound(to: Float32.self)
            let sourceChannels = max(Int(input.mNumberChannels), 1)
            let sourceSamples = Int(input.mDataByteSize) / MemoryLayout<Float32>.size
            let sourceFrames = sourceSamples / sourceChannels
            let scalar = gainPointer.pointee

            if outputs.count == 1, let destinationData = outputs[0].mData {
                let destination = destinationData.assumingMemoryBound(to: Float32.self)
                let destinationSamples = Int(outputs[0].mDataByteSize) / MemoryLayout<Float32>.size
                let count = min(sourceSamples, destinationSamples)
                var index = 0
                while index < count {
                    destination[index] = source[index] * scalar
                    index += 1
                }
                if count < destinationSamples {
                    memset(destination.advanced(by: count), 0, (destinationSamples - count) * MemoryLayout<Float32>.size)
                }
                return
            }

            // Non-interleaved output: copy the matching tap channel into each
            // device buffer and leave surplus hardware channels silent.
            for (channel, output) in outputs.enumerated() {
                guard let destinationData = output.mData else { continue }
                let destination = destinationData.assumingMemoryBound(to: Float32.self)
                let destinationSamples = Int(output.mDataByteSize) / MemoryLayout<Float32>.size
                guard channel < sourceChannels else {
                    memset(destinationData, 0, Int(output.mDataByteSize))
                    continue
                }
                let frames = min(sourceFrames, destinationSamples)
                var frame = 0
                while frame < frames {
                    destination[frame] = source[frame * sourceChannels + channel] * scalar
                    frame += 1
                }
                if frames < destinationSamples {
                    memset(destination.advanced(by: frames), 0, (destinationSamples - frames) * MemoryLayout<Float32>.size)
                }
            }
        }

        var newIOProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProc, newAggregate, nil, ioBlock)
        guard ioStatus == noErr, let newIOProc else {
            destroyHardware()
            throw error(ioStatus, "Could not connect to the output device")
        }
        ioProcID = newIOProc
    }

    func start() throws {
        guard !started, let ioProcID else { return }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw error(status, "Could not start software volume")
        }
        started = true
    }

    func destroy() {
        destroyHardware()
    }

    private func destroyHardware() {
        if let ioProcID {
            if started { AudioDeviceStop(aggregateID, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
            started = false
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func error(_ status: OSStatus, _ message: String) -> NSError {
        NSError(
            domain: "com.apotenza.SimpleMacFixes.audio",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(AudioHardware.describe(status))"]
        )
    }

    deinit {
        destroyHardware()
        gainPointer.deinitialize(count: 1)
        gainPointer.deallocate()
    }
}
