import CoreAudio
import Foundation

/// Core Audio delivers these control-property notifications on the main queue,
/// never on the real-time render callback. Registrations have explicit ownership.
final class AudioPropertyObservation {
    private let object: AudioObjectID
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(object: AudioObjectID, addresses: [AudioObjectPropertyAddress], onChange: @escaping @MainActor () -> Void) {
        self.object = object
        for candidate in addresses {
            var address = candidate
            guard AudioObjectHasProperty(object, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { onChange() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                registrations.append((address, block))
            }
        }
    }

    func cancel() {
        for (candidate, block) in registrations {
            var address = candidate
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        registrations.removeAll()
    }

    deinit { cancel() }
}
